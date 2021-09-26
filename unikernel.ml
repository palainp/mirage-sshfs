(*
 * Copyright (c) 2021 Pierre Alain <pierre.alain@tuta.io>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

open Lwt.Infix

module Main (N: Mirage_net.S) (_: Mirage_time.S) (B: Mirage_block.S) = struct

  let log_src = Logs.Src.create "sshfs_server" ~doc:"Server for sshfs"
  module Log = (val Logs.src_log log_src : Logs.LOG)

  module Sshfs = Sshfs.Make(B)
  module E = Ethernet.Make(N)

  
  let user_db disk user =
    let keyfile = String.concat "" [user; ".pub"] in
    Sshfs.file_buf disk keyfile >>= fun (key) ->
    Log.debug (fun f -> f "Auth granted for user `%s` with pubkey `%s` (`%s`)\n%!" user keyfile (Cstruct.to_string key));
    let key = Rresult.R.get_ok (Awa.Wire.pubkey_of_openssh key) in
    let awa = Awa.Auth.make_user user [ key ] in
    Lwt.return [ awa ]

  (* here we can have multiple messages in the queue *)
  let rec consume_messages input sshout _ssherror working_table disk () =
    if(Cstruct.length input < 5 (* or == 0 ? *)) then Lwt.return working_table
    else begin
      let len = Int32.to_int (Cstruct.BE.get_uint32 (Cstruct.sub input 0 4) 0) in
      Sshfs.reply (Cstruct.sub input 4 len) sshout _ssherror
        working_table (* internal structure, list open handles and associated datas *)
        disk
        ()
      >>= fun new_table -> consume_messages (Cstruct.sub input (len+4) ((Cstruct.length input)-len-4)) sshout _ssherror new_table disk ()
    end

  let rec sshfs_communication sshin sshout _ssherror working_table disk () =
    sshin () >>= function
    | `Eof -> Lwt.return_unit
    | `Data input -> consume_messages input sshout _ssherror working_table disk ()
    >>= fun new_table -> sshfs_communication sshin sshout _ssherror new_table disk ()

  let exec addr disk cmd sshin sshout _ssherror =
    Log.info (fun f -> f "[%s] executing `%s`\n%!" addr cmd);
    (match cmd with
      | "sftp" -> sshfs_communication sshin sshout _ssherror (Hashtbl.create 10) disk ()
      | _ -> Log.warn (fun f -> f "*** Subsystem %s is not implemented\n%!" cmd);
          Lwt.return_unit
    ) >>= fun () ->
    Log.info (fun f -> f "[%s] execution of `%s` finished\n%!" addr cmd);
    Lwt.return_unit
    (* XXX Awa_lwt must close the channel when exec returns ! *)

  let serve priv_key fd addr disk =
    Log.info (fun f -> f "[%s] connected\n%!" addr);
    let user = Key_gen.user () in
    user_db disk user >>= fun(users) ->
    let server, msgs = Awa.Server.make priv_key users in
    Awa_lwt.spawn_server server msgs fd (exec addr disk) >>= fun _t ->
    Log.info (fun f -> f "[%s] finished\n%!" addr);
    Lwt.return_unit

  let rec wait_connection priv_key listen_fd server_port disk =
    Log.info (fun f -> f "SSHFS server waiting connections on port %d\n%!" server_port);
    Lwt_unix.(accept listen_fd) >>= fun (client_fd, saddr) ->
    let client_addr = match saddr with
      | Lwt_unix.ADDR_UNIX s -> s
      | Lwt_unix.ADDR_INET (addr, port) ->
        Printf.sprintf "%s:%d" (Unix.string_of_inet_addr addr) port
    in
    Lwt.ignore_result (serve priv_key client_fd client_addr disk);
    wait_connection priv_key listen_fd server_port disk

  let start _ _ disk =
    (* Load the disk and init crypto *)
    Sshfs.connect disk >>= fun disk ->
    Mirage_crypto_rng_lwt.initialize ();
    let g = Mirage_crypto_rng.(create ~seed:(Cstruct.of_string "180586") (module Fortuna)) in
    let (ec_priv,_) = Mirage_crypto_ec.Ed25519.generate ~g () in
    let priv_key = Awa.Hostkey.Ed25519_priv (ec_priv) in

    let server_port = Key_gen.port () in

    let listen_fd = Lwt_unix.(socket PF_INET SOCK_STREAM 0) in
    Lwt_unix.(setsockopt listen_fd SO_REUSEADDR true);
    Lwt_unix.(bind listen_fd (ADDR_INET (Unix.inet_addr_any, server_port)))
    >>= fun () ->
    Lwt_unix.listen listen_fd 1;
    wait_connection priv_key listen_fd server_port disk

end