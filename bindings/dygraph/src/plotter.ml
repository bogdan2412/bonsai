[@@@js.dummy "!! This code has been generated by gen_js_api !!"]
[@@@ocaml.warning "-7-32-39"]
open! Core
open! Import
open! Gen_js_api
type t = Ojs.t
let rec t_of_js : Ojs.t -> t = fun (x2 : Ojs.t) -> x2
and t_to_js : t -> Ojs.t = fun (x1 : Ojs.t) -> x1
let (line_plotter : t) =
  t_of_js
    (Ojs.get_prop_ascii
       (Ojs.get_prop_ascii (Ojs.get_prop_ascii Ojs.global "Dygraph")
          "Plotters") "linePlotter")
let (fill_plotter : t) =
  t_of_js
    (Ojs.get_prop_ascii
       (Ojs.get_prop_ascii (Ojs.get_prop_ascii Ojs.global "Dygraph")
          "Plotters") "fillPlotter")
let (error_bar_plotter : t) =
  t_of_js
    (Ojs.get_prop_ascii
       (Ojs.get_prop_ascii (Ojs.get_prop_ascii Ojs.global "Dygraph")
          "Plotters") "errorPlotter")
let (point_plotter : t) =
  t_of_js
    (Ojs.get_prop_ascii
       (Ojs.get_prop_ascii (Ojs.get_prop_ascii Ojs.global "Dygraph")
          "Plotters") "pointPlotter")
