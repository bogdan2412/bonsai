open! Core
module Incr = Ui_incr

module Color = struct
  (* From  [bonsai.tailwind_colors]. *)
  let red50 = `Hex "#FEF2F2"
  let red100 = `Hex "#FEE2E2"
  let red200 = `Hex "#FECACA"
  let red300 = `Hex "#FCA5A5"
  let amber100 = `Hex "#FEF3C7"
  let amber200 = `Hex "#FDE68A"
  let blue100 = `Hex "#DBEAFE"
  let blue200 = `Hex "#BFDBFE"
  let blue300 = `Hex "#93C5FD"
  let emerald100 = `Hex "#D1FAE5"
  let emerald200 = `Hex "#A7F3D0"
  let pink100 = `Hex "#FCE7F3"
  let pink200 = `Hex "#FBCFE8"
  let pink300 = `Hex "#F9A8D4"
end

let enabled = ref false
let enable () = enabled := true
let disable () = enabled := false
let empty_attrs = String.Map.empty

let attribute_packed pos t =
  let pos =
    pos
    |> Source_code_position.to_string
    |> String.chop_prefix_if_exists ~prefix:"lib/"
    |> String.chop_prefix_if_exists ~prefix:"app/"
  in
  let labels =
    match String.rsplit2 ~on:'/' pos with
    | Some (l, r) -> [ "bound: " ^ l; "bound: " ^ r ]
    | None -> [ pos ]
  in
  List.iter labels ~f:(fun label ->
    let label = [ label ] in
    Incr.Packed.append_user_info_graphviz t ~label ~attrs:empty_attrs)
;;

module Kind = struct
  module T = struct
    type t =
      | Input
      | Value
      | Result
      | Lifecycle
      | Empty_lifecycle
      | Model
      | Model_and_input
      | Assoc_key
      | Assoc_input
      | Assoc_results
      | Assoc_lifecycles
      | Assoc_inputs
      | Path
      | Lifecycle_apply_action_pair
    [@@deriving hash, compare, sexp]
  end

  include T
  include Hashable.Make (T)

  let name = function
    | Input -> "input"
    | Value -> "value"
    | Result -> "result"
    | Lifecycle -> "lifecycle"
    | Empty_lifecycle -> "empty lifecycle"
    | Model -> "model"
    | Model_and_input -> "model & input"
    | Assoc_key -> "assoc key"
    | Assoc_input -> "assoc input"
    | Assoc_results -> "assoc result map"
    | Assoc_lifecycles -> "assoc lifecycle map"
    | Assoc_inputs -> "assoc input map"
    | Path -> "path"
    | Lifecycle_apply_action_pair -> "lifecycle/apply-action pair"
  ;;

  let color = function
    (* results
       red *)
    | Value -> Color.red50
    | Result -> Color.red100
    | Assoc_results -> Color.red200
    | Path -> Color.red300
    (* input
       amber *)
    | Input -> Color.amber100
    | Assoc_inputs -> Color.amber200
    (* lifecycles
       blue *)
    | Lifecycle -> Color.blue100
    | Assoc_lifecycles -> Color.blue200
    | Empty_lifecycle -> Color.blue300
    (* models
       green *)
    | Model -> Color.emerald100
    | Lifecycle_apply_action_pair -> Color.emerald200
    (* assoc-related
       pink *)
    | Model_and_input -> Color.pink100
    | Assoc_key -> Color.pink200
    | Assoc_input -> Color.pink300
  ;;
end

let annotate_packed =
  Memo.general ~hashable:Kind.hashable (fun kind incr ->
    let label = [ Kind.name kind ] in
    let (`Hex color) = Kind.color kind in
    let attrs = String.Map.of_alist_exn [ "style", "filled"; "fillcolor", color ] in
    Incr.Packed.append_user_info_graphviz incr ~label ~attrs)
;;

(* The "is enabled" check are performed here in order to avoid
   going through the memoization or allocation of a Packed.t even
   when disabled. *)
let annotate_packed kind incr = if !enabled then annotate_packed kind incr
let annotate kind incr = if !enabled then annotate_packed kind (Incr.pack incr)

let attribute_packed pos_opt t =
  match !enabled, pos_opt with
  | true, Some pos -> attribute_packed pos t
  | _ -> ()
;;

let attribute pos_opt incr = if !enabled then attribute_packed pos_opt (Incr.pack incr)
