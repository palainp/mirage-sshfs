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

module Main
    (_ : Mirage_random.S)
    (T : Mirage_time.S)
    (M : Mirage_clock.MCLOCK)
    (P : Mirage_clock.PCLOCK)
    (S : Tcpip.Stack.V4V6)
    (KV : Mirage_kv.RW) =
struct
  let log_src = Logs.Src.create "sshfs_server" ~doc:"Server for sshfs"

  module Log = (val Logs.src_log log_src : Logs.LOG)
  module AWA = Awa_mirage.Make (S.TCP) (T) (M)
  module SSHFS = Sshfs.Make (KV) (P)

  (* this funtion adds the user/key in the authorized user/key db.
     The server will consider only the first occurence, not adding any duplicate *)
  let add_key_of_string db user key =
    match Awa.Auth.lookup_user user db with
    | Some _ ->
        Log.debug (fun f ->
            f "Trying to add user `%s` but is already present..." user);
        Lwt.return db
    | None ->
        Log.debug (fun f ->
            f "Trying to add user `%s` with pubkey (`%s`)..." user key);
        let sshkey = Awa.Wire.pubkey_of_openssh (Cstruct.of_string key) in
        if Result.is_ok sshkey then (
          Log.debug (fun f -> f "Adding user `%s` with pubkey (`%s`)" user key);
          let db =
            List.cons (Awa.Auth.make_user user [ Result.get_ok sshkey ]) db
          in
          Lwt.return db)
        else Lwt.return db

  (* this populates the db of authorized users/keys *)
  let user_db disk =
    let db = [] in

    (* first we add the user/key taken from command line, this way the command line option
       will have the higher priority *)
    let default_user = Key_gen.user () in
    let default_key = Key_gen.key () in
    add_key_of_string db default_user default_key >>= fun db ->
    Log.debug (fun f -> f "default user %s added with default key %s" default_user default_key);
    (* then we scan the root directory for .pub files *)
    SSHFS.get_list_key disk >>= fun flist ->
    let rec add_pubkey_files db l =
      match l with
      | [] -> Lwt.return db
      | (key, typ) :: t -> (
          match typ with
          | `Value ->
              let file = Mirage_kv.Key.basename key in
              (* we need real files ending with .pub *)
              if String.ends_with ~suffix:".pub" file then
                (* we can sub 4 to the length as we know that the filename ends with ".pub" *)
                let len = String.length file - 4 in
                let user = String.sub file 0 len in
                SSHFS.get_disk_key disk file >>= fun key ->
                add_key_of_string db user key >>= fun db ->
                add_pubkey_files db t
              else add_pubkey_files db t
          | _ -> add_pubkey_files db t)
    in
    add_pubkey_files db flist >>= fun db ->
    (* then we scan the authorized_keys file. Warning the name is set in the stone here *)
    SSHFS.get_disk_key disk "authorized_keys" >>= fun keys ->
    let rec add_authorized_keys db l =
      match l with
      | [] -> Lwt.return db
      | k :: t ->
          (* format should be "type key information" (with type like rsa, ed, etc),
             key the hex string, and information any comment to the pubkey, here used as
             a user *)
          let toklist = String.split_on_char ' ' k in
          if List.length toklist >= 3 then
            let user = List.nth toklist 2 in
            add_key_of_string db user k >>= fun db -> add_authorized_keys db t
          else add_authorized_keys db t
    in
    let keys = String.split_on_char '\n' keys in
    add_authorized_keys db keys

  let rec sshfs_communication sshin sshout ssherror prev_data working_table
      disk () =
    (* here we can have multiple messages in the queue *)
    let rec consume_messages input sshout ssherror working_table disk () =
      (* if the message is empty *)
      if Cstruct.length input == 0 then Lwt.return (Cstruct.empty, working_table)
      else
        let len =
          Int32.to_int (Cstruct.BE.get_uint32 (Cstruct.sub input 0 4) 0)
        in
        (* if the message is too long for one sshin message *)
        if Cstruct.length input < len + 4 then Lwt.return (input, working_table)
        else
          (* in the other cases we can deal with it *)
          let data = Cstruct.sub input 4 len in
          SSHFS.reply data sshout ssherror working_table
            (* internal structure, list open handles and associated datas *)
            disk ()
          >>= fun new_table ->
          consume_messages
            (Cstruct.sub input (len + 4) (Cstruct.length input - len - 4))
            sshout ssherror new_table disk ()
    in
    sshin () >>= function
    | `Eof -> Lwt.return_unit
    | `Data input ->
        consume_messages
          (Cstruct.append prev_data input)
          sshout ssherror working_table disk ()
        >>= fun (remaining_data, new_table) ->
        sshfs_communication sshin sshout ssherror remaining_data new_table disk
          ()

  let exec addr disk req =
    match req with
    | AWA.Channel {cmd; ic; oc; ec; } ->
      Log.info (fun f -> f "[%s] executing `%s`\n%!" addr cmd);
      (match cmd with
      | "sftp" ->
          sshfs_communication ic oc ec Cstruct.empty
            (Hashtbl.create 10) disk ()
      | _ ->
          Log.info (fun f -> f "*** Subsystem %s is not implemented\n%!" cmd);
          Lwt.return_unit)
      >>= fun () ->
      Log.info (fun f -> f "[%s] execution of `%s` finished\n%!" addr cmd);
      Lwt.return_unit
    | _ ->
      Lwt.return_unit

  let serve priv_key flow addr disk =
    Log.info (fun f -> f "[%s] initiating connexion\n%!" addr);
    user_db disk >>= fun users ->
    Log.info (fun f -> f "We have %d possible users" (List.length users));
    let server, msgs = Awa.Server.make priv_key users in
    AWA.spawn_server server msgs flow (exec addr disk) >>= fun _t ->
    Log.info (fun f -> f "[%s] finished\n%!" addr);
    Lwt.return_unit

  let start _random _time _mclock _pclock stack disk =
    let seed = Key_gen.seed () in
    let g =
      Mirage_crypto_rng.(create ~seed:(Cstruct.of_string seed) (module Fortuna))
    in
    let ec_priv, _ = Mirage_crypto_ec.Ed25519.generate ~g () in
    let priv_key = Awa.Hostkey.Ed25519_priv ec_priv in
    let port = Key_gen.port () in
    S.TCP.listen (S.tcp stack) ~port (fun flow ->
        let dst, _ (*dst_port*) = S.TCP.dst flow in
        let addr = Ipaddr.to_string dst in
        serve priv_key flow addr disk >>= fun () -> S.TCP.close flow);

    Log.info (fun f -> f "SSHFS server waiting connections on port %d\n%!" port);
    S.listen stack
end
