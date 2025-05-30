open! Core
open Ppxlib
open Ast_builder.Default
open Ppx_let_expander
open Ppx_pattern_bind

module Location_behavior = struct
  type t =
    | Location_of_callsite (** Uses [~here:[%here]] *)
    | Location_in_scope (** Uses [~here:here] *)

  let to_ppx_let_behavior = function
    | Location_of_callsite -> Ppx_let_expander.With_location.Location_of_callsite
    | Location_in_scope -> Location_in_scope "here"
  ;;
end

let sub (location_behavior : Location_behavior.t) : (module Ext) =
  let module Sub : Ext = struct
    let name = "sub"
    let with_location = Location_behavior.to_ppx_let_behavior location_behavior
    let wrap_expansion = wrap_expansion_identity
    let prevent_tail_call = true

    let disallow_expression _ = function
      (* It is worse to use let%sub...and instead of multiple let%sub in a row,
       so disallow it. *)
      | Pexp_let (Nonrecursive, _ :: _ :: _, _) ->
        Error "let%sub should not be used with 'and'."
      | Pexp_while (_, _) -> Error "while%sub is not supported"
      | _ -> Ok ()
    ;;

    let already_has_nontail expr =
      List.exists expr.pexp_attributes ~f:(fun attribute ->
        String.equal attribute.attr_name.txt "nontail")
    ;;

    let sub_return ~loc ~modul ~lhs ~rhs ~body =
      let returned_rhs = qualified_return ~loc ~modul rhs in
      let body =
        match already_has_nontail body with
        | false -> nontail ~loc body
        | true -> body
      in
      bind_apply
        ~prevent_tail_call
        ~op_name:name
        ~loc
        ~modul
        ~with_location
        ~arg:returned_rhs
        ~fn:(pexp_fun Nolabel None ~loc lhs body)
        ()
    ;;

    let destruct ~assume_exhaustive ~loc ~modul ~lhs ~rhs ~body =
      match lhs.ppat_desc with
      | Ppat_var _ -> None
      | _ ->
        let bindings = [ value_binding ~loc ~pat:lhs ~expr:rhs ] in
        let pattern_projections =
          project_pattern_variables ~assume_exhaustive ~modul ~with_location bindings
        in
        Some
          (match pattern_projections with
           (* We handle the special case of having no pattern projections (which
            means there were no variables to be projected) by projecting the
            whole pattern once, just to ensure that the expression being
            projected matches the pattern. We only do this when the pattern is
            exhaustive, because otherwise the pattern matching is already
            happening inside the [switch] call. *)
           | [] when assume_exhaustive ->
             let projection_case = case ~lhs ~guard:None ~rhs:(eunit ~loc) in
             let fn = pexp_function ~loc [ projection_case ] in
             let rhs =
               bind_apply
                 ~op_name:Map.name
                 ~loc
                 ~modul
                 ~with_location
                 ~arg:rhs
                 ~fn
                 ()
                 ~prevent_tail_call
             in
             sub_return ~loc ~modul ~lhs:(ppat_any ~loc) ~rhs ~body
           | _ ->
             List.fold
               pattern_projections
               ~init:body
               ~f:(fun expr { txt = binding; loc = _ } ->
                 sub_return
                   ~loc:
                     { loc_start = lhs.ppat_loc.loc_start
                     ; loc_end = body.pexp_loc.loc_end
                     ; loc_ghost = true
                     }
                   ~modul
                   ~lhs:binding.pvb_pat
                   ~rhs:binding.pvb_expr
                   ~body:expr))
    ;;

    let focus_any =
      object
        inherit Ast_traverse.map as super

        method! pattern pattern =
          match pattern.ppat_desc with
          | Ppat_any -> Merlin_helpers.focus_pattern pattern
          | _ -> super#pattern pattern
      end
    ;;

    let switch ~loc ~switch_loc ~modul case_number case_number_cases =
      let case_number = focus_any#expression case_number in
      pexp_apply
        ~loc
        (eoperator ~loc:switch_loc ~modul "switch")
        [ ( Labelled "here"
          , match location_behavior with
            | Location_of_callsite -> Ppx_here_expander.lift_position ~loc:switch_loc
            | Location_in_scope -> evar ~loc "here" )
        ; Labelled "match_", { case_number with pexp_loc = switch_loc }
        ; Labelled "branches", eint ~loc:switch_loc (List.length case_number_cases - 1)
        ; Labelled "with_", pexp_function ~loc:switch_loc case_number_cases
        ]
    ;;

    (* Maps tuples of [('a Value.t * 'b Value.t ...)] to [('a * 'b ...) Value.t]  *)
    let match_tuple_mapper ~loc ~modul ~locality ~(expressions : expression list) =
      let open (val Ast_builder.make loc) in
      let temp_variable_to_expression =
        List.map expressions ~f:(fun expression ->
          let temp_name = gen_symbol ~prefix:"__ppx_bonsai_tuple" () in
          temp_name, expression)
      in
      let value_t_that_tuples_everything =
        let value_bindings =
          List.map temp_variable_to_expression ~f:(fun (temp_variable_name, expression) ->
            value_binding ~pat:(ppat_var (Located.mk temp_variable_name)) ~expr:expression)
        in
        let tuple_creation =
          pexp_tuple
            (List.map temp_variable_to_expression ~f:(fun (temp_variable_name, _) ->
               pexp_ident (Located.mk (Lident temp_variable_name))))
        in
        pexp_let Nonrecursive value_bindings tuple_creation
      in
      Ppx_let_expander.expand
        Ppx_let_expander.map
        Extension_kind.default
        ~modul
        ~locality
        value_t_that_tuples_everything
    ;;

    let expand_match ~loc ~modul ~locality expr =
      let expr =
        match Ppxlib_jane.Shim.Expression_desc.of_parsetree ~loc expr.pexp_desc with
        | Pexp_tuple labeled_expressions ->
          (match Ppxlib_jane.as_unlabeled_tuple labeled_expressions with
           | Some expressions ->
             match_tuple_mapper
               ~modul
               ~loc:{ expr.pexp_loc with loc_ghost = true }
               ~expressions
               ~locality
           | None -> expr)
        | _ -> expr
      in
      function
      | [] -> assert false
      | [ (case : case) ] ->
        let returned_expr = qualified_return ~loc ~modul expr in
        let fn =
          maybe_destruct
            ~destruct
            ~loc
            ~modul
            ~return_value_in_exclave:locality.return_value_in_exclave
            ~lhs:case.pc_lhs
            ~body:case.pc_rhs
        in
        bind_apply
          ~op_name:name
          ~loc
          ~modul
          ~with_location
          ~arg:returned_expr
          ~fn
          ~prevent_tail_call
          ()
      | _ :: _ :: _ as cases ->
        let var_name = gen_symbol ~prefix:"__pattern_syntax" () in
        let var_expression = evar ~loc var_name in
        let var_pattern = pvar ~loc var_name in
        let body = indexed_match ~loc ~modul ~destruct ~switch var_expression cases in
        sub_return ~loc ~modul ~lhs:var_pattern ~rhs:expr ~body
    ;;
  end
  in
  (module Sub : Ext)
;;

let arr (location_behavior : Location_behavior.t) : (module Ext) =
  let module Arr : Ext = struct
    let name = "arr"
    let with_location = Location_behavior.to_ppx_let_behavior location_behavior
    let prevent_tail_call = false

    let location_ghoster =
      object
        inherit Ast_traverse.map as super
        method! location loc = super#location { loc with loc_ghost = true }
      end
    ;;

    module Extracted_variable = struct
      type t =
        { original_label : label loc
        ; new_label : label loc
        ; old_label : label loc
        }

      let of_original_name : label loc -> t =
        fun original_label ->
        let new_label =
          { original_label with txt = gen_symbol ~prefix:"__new_for_cutoff" () }
        in
        let old_label =
          { original_label with txt = gen_symbol ~prefix:"__old_for_cutoff" () }
        in
        { original_label; old_label; new_label }
      ;;
    end

    let ignores_at_least_1_subpattern pattern =
      let ignore_finder =
        object
          inherit [bool] Ast_traverse.fold as super

          method! pattern (pattern : pattern) acc =
            match acc with
            | true -> true
            | false ->
              (match Ppxlib_jane.Shim.Pattern_desc.of_parsetree pattern.ppat_desc with
               (* let (_ as a) = x in ... *)
               | Ppat_alias (_, _) -> false
               | Ppat_any
               (* let { a ; b ; _ } = x in ... *)
               | Ppat_record (_, Open)
               (* let ~a, .. = x in ... *)
               | Ppat_tuple (_, Open)
               (* let { a = (module _) ; b } = x in ... *)
               | Ppat_unpack { txt = None; _ } -> true
               | Ppat_record (_, Closed)
               | Ppat_tuple (_, Closed)
               | Ppat_unpack { txt = Some _; _ } -> super#pattern pattern acc
               | _ -> super#pattern pattern acc)
        end
      in
      ignore_finder#pattern pattern false
    ;;

    let add_cutoff_to_value_binding ~loc ~modul value_binding =
      let variables =
        let variables_of =
          object
            inherit [string loc list] Ast_traverse.fold as super

            method! pattern p acc =
              let acc = super#pattern p acc in
              match p.ppat_desc with
              | Ppat_var var -> var :: acc
              | Ppat_alias (_, var) -> var :: acc
              | _ -> acc
          end
        in
        variables_of#pattern value_binding.pvb_pat []
      in
      let ident_to_extracted_variable, variables =
        List.fold_map ~init:String.Map.empty variables ~f:(fun acc variable ->
          let extracted_variable = Extracted_variable.of_original_name variable in
          Core.Map.set acc ~key:variable.txt ~data:extracted_variable, extracted_variable)
      in
      let old_pattern =
        replace_variable
          ~f:(fun label ->
            match Core.Map.find ident_to_extracted_variable label.txt with
            | None -> `Remove
            | Some extracted_variable -> `Rename extracted_variable.old_label.txt)
          value_binding.pvb_pat
      in
      let new_pattern =
        replace_variable
          ~f:(fun label ->
            match Core.Map.find ident_to_extracted_variable label.txt with
            | None -> `Remove
            | Some extracted_variable -> `Rename extracted_variable.new_label.txt)
          value_binding.pvb_pat
      in
      let located_ident_to_longident (label : label loc) : longident_loc =
        let { txt; loc } = label in
        { txt = lident txt; loc }
      in
      let phys_equalities =
        List.map variables ~f:(fun { old_label; new_label; original_label = _ } ->
          let old_label = pexp_ident ~loc (located_ident_to_longident old_label) in
          let new_label = pexp_ident ~loc (located_ident_to_longident new_label) in
          [%expr phys_equal [%e old_label] [%e new_label]])
      in
      let check =
        List.reduce phys_equalities ~f:(fun prev next -> [%expr [%e next] && [%e prev]])
      in
      let fn =
        match check with
        | None -> [%expr fun _ _ -> true]
        | Some check ->
          location_ghoster#expression
            [%expr fun [%p old_pattern] [%p new_pattern] -> [%e check]]
      in
      let expr =
        bind_apply
          ~prevent_tail_call
          ~fn_label:"equal"
          ~op_name:"cutoff"
          ~loc
          ~modul
          ~with_location:
            (match location_behavior with
             | Location_behavior.Location_of_callsite -> No_location
             | Location_behavior.Location_in_scope -> Location_in_scope "here")
          ~arg:value_binding.pvb_expr
          ~fn
          ()
      in
      { value_binding with pvb_expr = expr }
    ;;

    let maybe_add_cutoff_to_value_binding
      ~(loc : location)
      ~(modul : longident loc option)
      (value_binding : value_binding)
      =
      let loc = { loc with loc_ghost = true } in
      match ignores_at_least_1_subpattern value_binding.pvb_pat with
      | false -> value_binding
      | true -> add_cutoff_to_value_binding ~loc ~modul value_binding
    ;;

    let disallow_expression _ = function
      | Pexp_while (_, _) -> Error "while%%arr is not supported."
      | _ -> Ok ()
    ;;

    let destruct ~assume_exhaustive:_ ~loc:_ ~modul:_ ~lhs:_ ~rhs:_ ~body:_ = None

    (* These functions have been copied verbatim. *)
    module From_let_expander = struct
      (* Wrap a function body in [exclave_] *)
      let wrap_exclave ~loc expr = [%expr [%e expr]]

      let maybe_wrap_exclave ~loc ~locality expr =
        match locality with
        | `global -> expr
        | `local -> wrap_exclave ~loc expr
      ;;
    end

    module Expand_balanced = struct
      open From_let_expander

      module Min_and_max = struct
        type 'a t =
          { min : 'a
          ; max : 'a
          }
      end

      let find_min_and_max_position =
        object
          inherit [position Min_and_max.t] Ast_traverse.fold

          method! location location { min; max } =
            let min = Location.min_pos location.loc_start min
            and max = Location.max_pos location.loc_end max in
            { Min_and_max.min; max }
        end
      ;;

      let find_min_and_max_positions : pattern Nonempty_list.t -> position Min_and_max.t =
        fun bindings ->
        let (hd :: tl) = bindings in
        let init =
          { Min_and_max.min = hd.ppat_loc.loc_start; max = hd.ppat_loc.loc_end }
        in
        List.fold ~init tl ~f:(fun { min; max } pattern ->
          find_min_and_max_position#pattern pattern { min; max })
      ;;

      let tupleize (bindings : pattern Nonempty_list.t) ~build_multiarg_fun =
        let tuple_loc =
          let%tydi { min; max } = find_min_and_max_positions bindings in
          { loc_start = min; loc_end = max; loc_ghost = true }
        in
        (* Produces a tuple pattern, with the original names of the bindings. *)
        let tuple_pat_for_toplevel_f =
          ppat_tuple ~loc:tuple_loc (Nonempty_list.to_list bindings)
        in
        (* Produces an expression like [fun x1 x2 x3 ... xn -> (x1, x2, x3, ..., xn)] *)
        let tuplize_n_fun =
          let names_and_locs =
            Nonempty_list.mapi bindings ~f:(fun i { ppat_loc; _ } ->
              [%string "t%{i#Int}"], { ppat_loc with loc_ghost = true })
          in
          let tuple_exp =
            Nonempty_list.map names_and_locs ~f:(fun (name, loc) -> evar name ~loc)
            |> Nonempty_list.to_list
            |> pexp_tuple ~loc:tuple_loc
          in
          let args =
            Nonempty_list.map names_and_locs ~f:(fun (name, loc) -> pvar name ~loc)
          in
          build_multiarg_fun ~args ~body:tuple_exp
        in
        tuplize_n_fun, tuple_pat_for_toplevel_f
      ;;

      let expand
        ~loc
        ~modul
        ~locality
        ~(with_location : With_location.t)
        ~n
        ppx_bindings
        ppx_body
        =
        let operator ~op_name = function
          | 1 -> eoperator ~loc ~modul op_name
          | n -> eoperator ~loc ~modul [%string "%{op_name}%{n#Int}"]
        in
        let build_multiarg_fun ~args ~body =
          Nonempty_list.fold_right
            args
            ~init:(maybe_wrap_exclave ~loc ~locality body)
            ~f:(fun pat inner ->
              maybe_destruct
                ~destruct
                ~modul
                ~return_value_in_exclave:false
                ~loc
                ~lhs:pat
                ~body:inner)
        in
        let build_application unlabelled_exps ~f_exp ~op_name =
          let args =
            (match with_location with
             | With_location.No_location -> []
             | With_location.Location_of_callsite ->
               [ Ppx_let_expander.location_arg ~loc ]
             | With_location.Location_in_scope name ->
               [ Ppx_let_expander.location_arg_in_scope ~loc name ])
            @ (Nonempty_list.map unlabelled_exps ~f:(fun exp -> Nolabel, exp)
               |> Nonempty_list.to_list)
            @ [ Labelled "f", f_exp ]
          in
          pexp_apply ~loc (operator ~op_name (Nonempty_list.length unlabelled_exps)) args
        in
        let rec loop = function
          | Balance_list_tree.Leaf vb -> vb.pvb_expr, vb.pvb_pat
          | Node children ->
            let exps, pats = Nonempty_list.map children ~f:loop |> Nonempty_list.unzip in
            let tuplize_n_fun, tuple_pat_for_toplevel_f =
              tupleize pats ~build_multiarg_fun
            in
            let mapn_exp =
              (* NOTE: We are using [map] here instead of [arr] for backwards compatibility
               with the [Proc] API. Using [map] is safe here as each [map] call is only
               used/depended on once. *)
              build_application exps ~f_exp:tuplize_n_fun ~op_name:"map"
            in
            mapn_exp, tuple_pat_for_toplevel_f
        in
        match Balance_list_tree.balance ~n ppx_bindings with
        | Error err -> invalid_arg (Error.to_string_hum err)
        | Ok balanced ->
          let subtrees =
            match balanced with
            | Balance_list_tree.Leaf _ -> Nonempty_list.singleton balanced
            | Node xs -> xs
          in
          let exps, pats = Nonempty_list.map subtrees ~f:loop |> Nonempty_list.unzip in
          let f_exp = build_multiarg_fun ~args:pats ~body:ppx_body in
          build_application exps ~f_exp ~op_name:"arr"
      ;;
    end

    let wrap_expansion
      :  loc:location -> modul:longident loc option -> value_binding list -> expression
      -> expand:(loc:location -> value_binding list -> expression -> expression)
      -> expression
      =
      fun ~loc ~modul value_bindings expression ~expand:_ ->
      let value_bindings =
        List.map value_bindings ~f:(maybe_add_cutoff_to_value_binding ~loc ~modul)
      in
      Expand_balanced.expand
        ~loc
        ~modul
        ~locality:`global
        ~with_location
        ~n:7
        value_bindings
        expression
    ;;

    let expand_match ~loc ~modul ~(locality : Locality.t) expr cases =
      (match locality with
       | { allocate_function_on_stack = false; return_value_in_exclave = false } -> ()
       | _ -> Location.raise_errorf ~loc "ppx_bonsai supports neither [bindl] nor [mapl]");
      bind_apply
        ~prevent_tail_call
        ~loc
        ~modul
        ~with_location
        ~op_name:name
        ~arg:expr
        ~fn:(pexp_function ~loc cases)
        ()
    ;;
  end
  in
  (module Arr : Ext)
;;

module For_testing = struct
  module Balance_list_tree = Balance_list_tree
end
