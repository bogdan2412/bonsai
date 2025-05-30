open! Core
open! Import

let () = Incr.State.(set_max_height_allowed t 1024)

let rec gather : type result. result Computation.gather_fun =
  let open Computation in
  fun ~recursive_scopes ~time_source -> function
    | Return { value; here } -> Eval_return.f ~value ~here
    | Leaf1 { model; input_id; dynamic_action; apply_action; input; reset; here } ->
      Eval_leaf1.f
        ~model
        ~input_id
        ~dynamic_action
        ~apply_action
        ~input
        ~reset
        ~time_source
        ~here
    | Leaf0 { model; static_action; apply_action; reset; here } ->
      Eval_leaf0.f ~model ~static_action ~time_source ~apply_action ~reset ~here
    | Leaf_incr { input; compute; here } ->
      Eval_leaf_incr.f ~input ~compute ~time_source ~here
    | Sub
        { into =
            Sub
              { into = Sub { invert_lifecycles = false; _ }
              ; invert_lifecycles = false
              ; _
              }
        ; invert_lifecycles = false
        ; _
        } as t ->
      (* [invert_ordering] nodes reuse [Sub] mechanics, (in the sense of passing the
          output of one computation to another), but should be thought of as their own
          "kind" of node, and aren't interoperable with the chain of subs generated via
          graph application. We only chain for 3 subsequent non-inverted [Sub]s, since
          a chain of at least 3 nodes is required for balancing to be useful. *)
      Eval_sub.chain t ~gather:{ f = gather } ~recursive_scopes ~time_source
    | Sub { from; via; into; invert_lifecycles; here } ->
      let%bind.Trampoline (T info_from) = gather ~recursive_scopes ~time_source from in
      let%bind.Trampoline (T info_into) = gather ~recursive_scopes ~time_source into in
      Trampoline.return
        (Eval_sub.gather ~here ~info_from ~info_into ~invert_lifecycles ~via)
    | Store { id; value; inner; here = _ } ->
      Eval_store.f ~gather ~recursive_scopes ~time_source ~id ~value ~inner
    | Fetch { id; default; for_some; here } -> Eval_fetch.f ~id ~default ~for_some ~here
    | Assoc { map; key_comparator; key_id; cmp_id; data_id; by; here } ->
      Eval_assoc.f
        ~gather
        ~recursive_scopes
        ~time_source
        ~map
        ~key_comparator
        ~key_id
        ~cmp_id
        ~data_id
        ~by
        ~here
    | Assoc_on
        { map
        ; io_comparator
        ; model_comparator
        ; io_key_id
        ; io_cmp_id
        ; model_key_id
        ; model_cmp_id
        ; data_id
        ; by
        ; get_model_key
        ; here
        } ->
      Eval_assoc_on.f
        ~gather
        ~recursive_scopes
        ~time_source
        ~map
        ~io_comparator
        ~model_comparator
        ~io_key_id
        ~io_cmp_id
        ~model_key_id
        ~model_cmp_id
        ~data_id
        ~by
        ~get_model_key
        ~here
    | Assoc_simpl { map; by; may_contain; here } ->
      Eval_assoc_simple.f ~map ~by ~may_contain ~here
    | Switch { match_; arms; here } ->
      Eval_switch.f ~gather ~recursive_scopes ~time_source ~match_ ~arms ~here
    | Lazy { t = lazy_computation; here } ->
      Eval_lazy.f ~gather ~recursive_scopes ~time_source ~lazy_computation ~here
    | Fix_define { fix_id; initial_input; input_id; result; here } ->
      Eval_fix.define
        ~gather
        ~recursive_scopes
        ~time_source
        ~fix_id
        ~initial_input
        ~input_id
        ~result
        ~here
    | Fix_recurse { input; input_id; fix_id; here } ->
      Eval_fix.recurse ~recursive_scopes ~input ~input_id ~fix_id ~here
    | Wrap
        { wrapper_model
        ; action_id
        ; result_id
        ; inject_id
        ; model_id
        ; inner
        ; dynamic_apply_action
        ; reset
        ; here
        } ->
      Eval_wrap.f
        ~here
        ~gather
        ~recursive_scopes
        ~time_source
        ~wrapper_model
        ~action_id
        ~result_id
        ~inject_id
        ~model_id
        ~inner
        ~dynamic_apply_action
        ~reset
    | With_model_resetter { inner; reset_id; here } ->
      Eval_with_model_resetter.f
        ~gather
        ~recursive_scopes
        ~time_source
        ~inner
        ~reset_id
        ~here
    | Path { here } -> Eval_path.f ~here
    | Lifecycle { lifecycle; here } -> Eval_lifecycle.f ~lifecycle ~here
    | Computation_watcher
        { here
        ; enable_watcher
        ; inner
        ; free_vars
        ; config
        ; queue
        ; value_type_id_observation_definition_positions
        } ->
      Eval_computation_watcher.f
        ~enable_watcher
        ~gather
        ~recursive_scopes
        ~time_source
        ~inner
        ~free_vars
        ~config
        ~watcher_queue:queue
        ~here
        ~value_type_id_observation_definition_positions
;;

let gather ~recursive_scopes ~time_source c =
  Trampoline.run (gather ~recursive_scopes ~time_source c)
;;
