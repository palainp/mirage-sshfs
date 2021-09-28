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

module Main (_: Mirage_random.S) (M : Mirage_clock.MCLOCK) (S: Mirage_stack.V4) (B: Mirage_block.S) = struct

  let log_src = Logs.Src.create "sshfs_server" ~doc:"Server for sshfs"
  module Log = (val Logs.src_log log_src : Logs.LOG)

  module F = S.TCPV4
  module AWA_MIRAGE = Awa_mirage.Make(F)(M)
  module SSHFS = Sshfs.Make(B)
  
  let user_db disk user =
    let keyfile = String.concat "" [user; ".pub"] in
    SSHFS.file_buf disk keyfile >>= fun (key) ->
    Log.debug (fun f -> f "Auth granted for user `%s` with pubkey `%s` (`%s`)\n%!" user keyfile (Cstruct.to_string key));
    let key = Rresult.R.get_ok (Awa.Wire.pubkey_of_openssh key) in
    let awa = Awa.Auth.make_user user [ key ] in
    Lwt.return [ awa ]

  (* here we can have multiple messages in the queue *)
  let rec consume_messages input sshout _ssherror working_table disk () =
    if(Cstruct.length input < 5 (* or == 0 ? *)) then Lwt.return working_table
    else begin
      let len = Int32.to_int (Cstruct.BE.get_uint32 (Cstruct.sub input 0 4) 0) in
      SSHFS.reply (Cstruct.sub input 4 len) sshout _ssherror
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

  let serve priv_key flow addr disk =
    Log.info (fun f -> f "[%s] connected\n%!" addr);
    let user = Key_gen.user () in
    user_db disk user >>= fun(users) ->
    let server, msgs = Awa.Server.make priv_key users in
    AWA_MIRAGE.spawn_server server msgs flow (exec addr disk) >>= fun _t ->
    Log.info (fun f -> f "[%s] finished\n%!" addr);
    Lwt.return_unit

  let start _ _ stack disk =
    SSHFS.connect disk >>= fun disk ->

    let g = Mirage_crypto_rng.(create ~seed:(Cstruct.of_string "180586") (module Fortuna)) in
    let (ec_priv,_) = Mirage_crypto_ec.Ed25519.generate ~g () in
    let priv_key = Awa.Hostkey.Ed25519_priv (ec_priv) in
    
    let port = Key_gen.port () in
    S.listen_tcpv4 stack ~port (fun flow -> 
        let dst, _ (*dst_port*) = S.TCPV4.dst flow in
        let addr = Ipaddr.V4.to_string dst in
        serve priv_key flow addr disk >>= fun () ->
        S.TCPV4.close flow
      );

    Log.info (fun f -> f "SSHFS server waiting connections on port %d\n%!" port);
    S.listen stack

end
