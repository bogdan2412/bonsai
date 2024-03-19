open! Core
open! Bonsai_web
open Bonsai.Let_syntax
module Gallery = Bonsai_web_ui_gallery
module Notifications = Bonsai_web_ui_notifications

module User_defined_notification = struct
  let name = "User defined notifications"

  let description =
    {| You can define your own notification type to represent your domain specific logic.
       The API also gives you control for how your notifications are rendered. |}
  ;;

  include
    [%demo
    module Notification = struct
      type t =
        | Success of string
        | Error of string
      [@@deriving sexp, equal]

      let render ~close t =
        let%sub theme = View.Theme.current in
        let%arr close = close
        and t = t
        and theme = theme in
        match t with
        | Success message ->
          View.card theme ~intent:Success ~on_click:close ~title:"Success" message
        | Error error ->
          View.card theme ~intent:Error ~on_click:close ~title:"Error" error
      ;;
    end

    let component =
      let%sub notifications =
        Notifications.component (module Notification) ~equal:[%equal: Notification.t]
      in
      let%sub vdom = Notifications.render notifications ~f:Notification.render in
      let%arr vdom = vdom
      and notifications = notifications in
      vdom, notifications
    ;;]

  let view =
    let%sub theme = View.Theme.current in
    let%sub component, notifications = component in
    let%arr component = component
    and notifications = notifications
    and theme = theme in
    let vdom =
      View.hbox
        ~gap:(`Em 1)
        [ View.button
            theme
            ~on_click:
              (Effect.ignore_m
                 (Notifications.send_notification notifications (Success "Yay!")))
            ~intent:Success
            "Send success notification"
        ; View.button
            theme
            ~on_click:
              (Effect.ignore_m
                 (Notifications.send_notification notifications (Error "Whoops!")))
            ~intent:Error
            "Send error notification"
        ; View.button
            theme
            ~on_click:
              (Effect.ignore_m (Notifications.close_all_notifications notifications))
            ~intent:Info
            "Close all notiifications"
        ; View.button
            theme
            ~on_click:
              (Effect.ignore_m (Notifications.close_oldest_notification notifications))
            ~intent:Info
            "Close oldest notiification"
        ; View.button
            theme
            ~on_click:
              (Effect.ignore_m (Notifications.close_newest_notification notifications))
            ~intent:Info
            "Close newest notiification"
        ; component
        ]
    in
    vdom, ppx_demo_string
  ;;

  let selector = None
  let filter_attrs = None
end

let component =
  let%sub theme, theme_picker = Gallery.Theme_picker.component () in
  View.Theme.set_for_app
    theme
    (Gallery.make_sections
       ~theme_picker
       [ ( "Notifications"
         , {| Notifications are a way of grabbing your users attention and letting your users
         know that things are happening, or maybe not happening, failed, kinda failed and more!

        Notifications pick the apply the right css styles so that your in-app
        notifications appear in front of your content. |}
         , [ Gallery.make_demo (module User_defined_notification) ] )
       ])
;;

let () = Bonsai_web.Start.start component
