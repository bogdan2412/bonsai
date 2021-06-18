open! Core
open! Import

module type Conv = sig
  type t

  val of_string : string -> t
  val to_string_hum : t -> string
end

val component
  :  (module Conv with type t = 't)
  -> default_model:string
  -> ('t Or_error.t * Vdom.Node.t) Import.Computation.t
