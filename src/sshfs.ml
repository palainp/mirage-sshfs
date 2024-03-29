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
open Helpers

module Make (KV : Mirage_kv.RW) (P : Mirage_clock.PCLOCK) = struct
  let log_src =
    Logs.Src.create "sshfs_protocol" ~doc:"Protocol dealer for sshfs"

  module Log = (val Logs.src_log log_src : Logs.LOG)
  module FS = Fs.Make (KV) (P)

  let fail fmt = Fmt.kstr Lwt.fail_with fmt
  let get_list_key disk = FS.lsdir disk "/"

  let get_disk_key disk filename =
    FS.size disk filename >>= fun s ->
    FS.read disk filename ~offset:(Optint.Int63.of_int 0) ~length:s >>= function
    | Error _ -> Lwt.return ""
    | Ok data -> Lwt.return data

  let payload_of_string s =
    Cstruct.concat
      [ uint32_to_cs (Int32.of_int (String.length s)); Cstruct.of_string s ]

  (* sftp message is length(4 bytes) + type(1 byte) + data (length-1 bytes, starting with request-id:4 bytes) *)
  let to_client typ payload =
    Cstruct.concat
      [
        uint32_to_cs (Int32.of_int (1 + Cstruct.length payload));
        uint8_to_cs (Sshfs_tag.sshfs_packtype_to_uint8 typ);
        payload;
      ]

  let from_client msg =
    let typ = Sshfs_tag.sshfs_packtype_of_uint8 (Cstruct.get_uint8 msg 0) in
    let dat = Cstruct.sub msg 1 (Cstruct.length msg - 1) in
    (typ, dat)

  let reply_handle root path =
    FS.path_to_handle root path >>= fun handle ->
    Lwt.return (handle, Sshfs_tag.SSH_FXP_HANDLE, payload_of_string handle)

  (* version 3 used by openssh : https://filezilla-project.org/specs/draft-ietf-secsh-filexfer-02.txt *)
  let reply message sshout _ssherror working_table root () =
    let request_type, data = from_client message in
    let id = uint32_of_cs (Cstruct.sub data 0 4) in
    (* request-id *)
    Log.debug (fun f ->
        f "[%ld received: raw type is %d]\n%!" id
          (Sshfs_tag.sshfs_packtype_to_uint8 request_type));
    match request_type with
    (* 4. Protocol Initialization *)
    | SSH_FXP_INIT ->
        Log.debug (fun f -> f "[SSH_FXP_INIT with version %ld]\n%!" id);
        sshout
          (to_client SSH_FXP_VERSION
             (uint32_to_cs (min 3l (uint32_of_cs data))))
        >>= fun () -> Lwt.return working_table
    (* 6.8 Retrieving File Attributes *)
    | SSH_FXP_STAT
    | SSH_FXP_LSTAT -> (* So far we don't bother with symlinks... *)
        let path_length = Int32.to_int (uint32_of_cs (Cstruct.sub data 4 4)) in
        let path = Cstruct.to_string (Cstruct.sub data 8 path_length) in
        Log.debug (fun f -> f "[SSH_FXP_?STAT %ld] for '%s'\n%!" id path);
        FS.permission root path >>= fun (reply_type, payload) ->
        sshout
          (to_client reply_type (Cstruct.concat [ uint32_to_cs id; payload ]))
        >>= fun () ->
        Lwt.return working_table
    (* 6.8 Retrieving File Attributes *)
    | SSH_FXP_FSTAT ->
        let handle_length =
          Int32.to_int (uint32_of_cs (Cstruct.sub data 4 4))
        in
        let handle = Cstruct.to_string (Cstruct.sub data 8 handle_length) in
        FS.path_of_handle root handle >>= fun path ->
        Log.debug (fun f -> f "[SSH_FXP_FSTAT %ld] for %s\n%!" id path);
        FS.permission root path >>= fun (reply_type, payload) ->
        sshout
          (to_client reply_type (Cstruct.concat [ uint32_to_cs id; payload ]))
        >>= fun () -> Lwt.return working_table
    (* 6.7 Scanning Directories *)
    | SSH_FXP_OPENDIR -> (
        (* TODO: find a better way to deal with handles and file/dirnames *)
        let path_length = Int32.to_int (uint32_of_cs (Cstruct.sub data 4 4)) in
        let path = Cstruct.to_string (Cstruct.sub data 8 path_length) in
        Log.debug (fun f -> f "[SSH_FXP_OPENDIR %ld] for '%s'\n%!" id path);

        match Hashtbl.find_opt working_table path with
        | None ->
            (* if the handle is not already opened -> open it and add content of this directory into the working table *)
            reply_handle root path >>= fun (handle, reply_type, payload) ->
            Log.debug (fun f ->
                f "[SSH_FXP_OPENDIR %ld] handle is '%s'\n%!" id handle);
            sshout
              (to_client reply_type
                 (Cstruct.concat [ uint32_to_cs id; payload ]))
            >>= fun () ->
            (* Puts every item as Mirage_kv.Key.t in the hash table *)
            FS.lsdir root path >>= fun names ->
            Hashtbl.add working_table handle names;
            Lwt.return working_table
        | _ ->
            (* if the handle is already opened -> error *)
            let payload =
              uint32_to_cs
                (Sshfs_tag.sshfs_errcode_to_uint32 SSH_FX_OP_UNSUPPORTED)
            in
            sshout
              (to_client SSH_FXP_STATUS
                 (Cstruct.concat [ uint32_to_cs id; payload ]))
            >>= fun () -> Lwt.return working_table)
    (* 6.7 Scanning Directories *)
    | SSH_FXP_READDIR -> (
        (* TODO: remove the ugly long-name constant... *)
        let handle_length =
          Int32.to_int (uint32_of_cs (Cstruct.sub data 4 4))
        in
        let handle = Cstruct.to_string (Cstruct.sub data 8 handle_length) in
        Log.debug (fun f -> f "[SSH_FXP_READDIR %ld] for '%s'\n%!" id handle);

        match Hashtbl.find_opt working_table handle with
        | None ->
            (* if the handle is not already opened -> error *)
            let payload =
              uint32_to_cs
                (Sshfs_tag.sshfs_errcode_to_uint32 SSH_FX_INVALID_HANDLE)
            in
            sshout
              (to_client SSH_FXP_STATUS
                 (Cstruct.concat [ uint32_to_cs id; payload ]))
            >>= fun () -> Lwt.return working_table
        | remaining_list -> (
            (* if the handle is already opened -> reply to the client or EOF *)
            let remaining_list = Option.get remaining_list in
            match remaining_list with
            | [] ->
                (* if we exhausted the list of files/folder inside the requested handle *)
                Log.debug (fun f ->
                    f "[SSH_FXP_READDIR %ld] for '%s' no more content\n%!" id
                      handle);
                let payload =
                  uint32_to_cs (Sshfs_tag.sshfs_errcode_to_uint32 SSH_FX_EOF)
                in
                sshout
                  (to_client SSH_FXP_STATUS
                     (Cstruct.concat [ uint32_to_cs id; payload ]))
                >>= fun () -> Lwt.return working_table
            | (head, _) :: tail ->
                (* if we still have something to give: it's a Mirage_kv.Key.t *)
                let name = Mirage_kv.Key.basename head in
                let path = Mirage_kv.Key.to_string head in
                Log.debug (fun f ->
                    f "[SSH_FXP_READDIR %ld] for '%s' giving '%s'\n%!" id handle
                      name);
                FS.permission root path >>= fun (_, stats) ->
                let payload =
                  Cstruct.concat
                    [
                      uint32_to_cs 1l;
                      (* count the number of names returned *)
                      payload_of_string name;
                      (* short-name *)
                      payload_of_string
                        "1234567890123123456781234567812345678123456789012";
                      (* FIXME: long-name *)
                      stats;
                    ]
                in
                sshout
                  (to_client SSH_FXP_NAME
                     (Cstruct.concat [ uint32_to_cs id; payload ]))
                >>= fun () ->
                Hashtbl.replace working_table handle tail;
                Lwt.return working_table))
    (* 6.3 Opening, Creating, and Closing Files *)
    | SSH_FXP_OPEN -> (
        let path_length = Int32.to_int (uint32_of_cs (Cstruct.sub data 4 4)) in
        let path = Cstruct.to_string (Cstruct.sub data 8 path_length) in
        let pflags =
          Int32.to_int (uint32_of_cs (Cstruct.sub data (8 + path_length) 4))
        in
        let attrs =
          Int32.to_int (uint32_of_cs (Cstruct.sub data (8 + path_length + 4) 4))
        in
        Log.debug (fun f ->
            f "[SSH_FXP_OPEN %ld] for '%s' pflags=%d attrs=%d\n%!" id path
              pflags attrs);

        reply_handle root path >>= fun (handle, reply_type, payload) ->
        match Hashtbl.find_opt working_table handle with
        | None ->
            (* if the handle is not already opened *)
            FS.instruct_pflags pflags root path >>= fun () ->
            sshout
              (to_client reply_type
                 (Cstruct.concat [ uint32_to_cs id; payload ]))
            >>= fun () ->
            Hashtbl.add working_table handle [];
            Lwt.return working_table
        | _ ->
            (* if the handle is already opened -> error *)
            let payload =
              uint32_to_cs
                (Sshfs_tag.sshfs_errcode_to_uint32 SSH_FX_OP_UNSUPPORTED)
            in
            sshout
              (to_client SSH_FXP_STATUS
                 (Cstruct.concat [ uint32_to_cs id; payload ]))
            >>= fun () -> Lwt.return working_table)
    (* 6.4 Reading and Writing *)
    | SSH_FXP_READ -> (
        let handle_length =
          Int32.to_int (uint32_of_cs (Cstruct.sub data 4 4))
        in
        let handle = Cstruct.to_string (Cstruct.sub data 8 handle_length) in
        let offset =
          Int64.to_int (uint64_of_cs (Cstruct.sub data (8 + handle_length) 8))
        in
        let length =
          Int32.to_int
            (uint32_of_cs (Cstruct.sub data (8 + handle_length + 8) 4))
        in

        FS.path_of_handle root handle >>= fun path ->
        Log.debug (fun f ->
            f "[SSH_FXP_READ %ld] for '%s' @%d (%d)\n%!" id path offset length);
        FS.read root path ~offset:(Optint.Int63.of_int offset) ~length >>= function
        | Error _ ->
            let payload =
              uint32_to_cs (Sshfs_tag.sshfs_errcode_to_uint32 SSH_FX_EOF)
            in
            sshout
              (to_client SSH_FXP_STATUS
                 (Cstruct.concat [ uint32_to_cs id; payload ]))
            >>= fun () -> Lwt.return working_table
        | Ok data ->
            let payload = Cstruct.of_string data in
            sshout
              (to_client SSH_FXP_DATA
                 (Cstruct.concat
                    [
                      uint32_to_cs id;
                      uint32_to_cs (Int32.of_int (Cstruct.length payload));
                      payload;
                    ]))
            >>= fun () -> Lwt.return working_table)
    (* 6.3 Opening, Creating, and Closing Files *)
    | SSH_FXP_CLOSE -> (
        let handle_length =
          Int32.to_int (uint32_of_cs (Cstruct.sub data 4 4))
        in
        let handle = Cstruct.to_string (Cstruct.sub data 8 handle_length) in
        Log.debug (fun f -> f "[SSH_FXP_CLOSE %ld] for %s\n%!" id handle);

        match Hashtbl.find_opt working_table handle with
        | None ->
            (* if the handle is not already opened -> error *)
            let payload =
              uint32_to_cs
                (Sshfs_tag.sshfs_errcode_to_uint32 SSH_FX_INVALID_HANDLE)
            in
            sshout
              (to_client SSH_FXP_STATUS
                 (Cstruct.concat [ uint32_to_cs id; payload ]))
            >>= fun () -> Lwt.return working_table
        | _ ->
            (* if the handle is already opened -> remove the handle entry in the hash table *)
            let payload =
              uint32_to_cs (Sshfs_tag.sshfs_errcode_to_uint32 SSH_FX_OK)
            in
            sshout
              (to_client SSH_FXP_STATUS
                 (Cstruct.concat [ uint32_to_cs id; payload ]))
            >>= fun () ->
            Hashtbl.remove working_table handle;
            Lwt.return working_table)
    (* 6.6 Creating and Deleting Directories *)
    | SSH_FXP_RMDIR
      (* TODO: check for the result & reply error when dir is not empty... *)
    | SSH_FXP_REMOVE ->
        (* TODO: check for the result *)
        let path_length = Int32.to_int (uint32_of_cs (Cstruct.sub data 4 4)) in
        let path = Cstruct.to_string (Cstruct.sub data 8 path_length) in
        Log.debug (fun f -> f "[SSH_FXP_REMOVE %ld] for %s\n%!" id path);

        FS.remove root path >>= fun _ ->
        (* FIXME: we always reply with status ok... *)
        let payload =
          uint32_to_cs (Sshfs_tag.sshfs_errcode_to_uint32 SSH_FX_OK)
        in
        sshout
          (to_client SSH_FXP_STATUS
             (Cstruct.concat [ uint32_to_cs id; payload ]))
        >>= fun () -> Lwt.return working_table
    (* 6.5 Removing and Renaming Files *)
    | SSH_FXP_RENAME ->
        let path_length = Int32.to_int (uint32_of_cs (Cstruct.sub data 4 4)) in
        let path = Cstruct.to_string (Cstruct.sub data 8 path_length) in
        let newpath_length =
          Int32.to_int (uint32_of_cs (Cstruct.sub data (8 + path_length) 4))
        in
        let newpath =
          Cstruct.to_string
            (Cstruct.sub data (8 + path_length + 4) newpath_length)
        in
        Log.debug (fun f ->
            f "[SSH_FXP_RENAME %ld] for %s->%s\n%!" id path newpath);

        (* FIXME: we always reply with status ok... Deal with possible returned errors *)
        FS.rename root path newpath >>= fun _ ->
        let payload =
          uint32_to_cs (Sshfs_tag.sshfs_errcode_to_uint32 SSH_FX_OK)
        in
        sshout
          (to_client SSH_FXP_STATUS
             (Cstruct.concat [ uint32_to_cs id; payload ]))
        >>= fun () -> Lwt.return working_table
    (* 6.6 Creating and Deleting Directories *)
    | SSH_FXP_MKDIR ->
        (* TODO: check for the result *)
        let path_length = Int32.to_int (uint32_of_cs (Cstruct.sub data 4 4)) in
        let path = Cstruct.to_string (Cstruct.sub data 8 path_length) in
        Log.debug (fun f -> f "[SSH_FXP_MKDIR %ld] for %s\n%!" id path);

        FS.mkdir root path >>= fun _ ->
        (* FIXME: we always reply with status ok... *)
        let payload =
          uint32_to_cs (Sshfs_tag.sshfs_errcode_to_uint32 SSH_FX_OK)
        in
        sshout
          (to_client SSH_FXP_STATUS
             (Cstruct.concat [ uint32_to_cs id; payload ]))
        >>= fun () -> Lwt.return working_table
    (* 6.9 Setting File Attributes *)
    | SSH_FXP_SETSTAT ->
        (* TODO: ex: touch, for now we do not much with this kind of informations *)
        let path_length = Int32.to_int (uint32_of_cs (Cstruct.sub data 4 4)) in
        let path = Cstruct.to_string (Cstruct.sub data 8 path_length) in
        (* let attrs = ??? *)
        Log.debug (fun f -> f "[SSH_FXP_SETSTAT %ld] for %s\n%!" id path);

        (* FIXME: we always reply with status ok... *)
        let payload =
          uint32_to_cs (Sshfs_tag.sshfs_errcode_to_uint32 SSH_FX_OK)
        in
        sshout
          (to_client SSH_FXP_STATUS
             (Cstruct.concat [ uint32_to_cs id; payload ]))
        >>= fun () -> Lwt.return working_table
    (* 6.9 Setting File Attributes *)
    | SSH_FXP_FSETSTAT -> (
        (* TODO: ex: touch, for now we do not much with this kind of informations *)
        let handle_length =
          Int32.to_int (uint32_of_cs (Cstruct.sub data 4 4))
        in
        let handle = Cstruct.to_string (Cstruct.sub data 8 handle_length) in
        (* let attrs = ??? *)
        Log.debug (fun f -> f "[SSH_FXP_FSETSTAT %ld] for %s\n%!" id handle);

        match Hashtbl.find_opt working_table handle with
        | None ->
            (* if the handle is not already opened -> error *)
            let payload =
              uint32_to_cs
                (Sshfs_tag.sshfs_errcode_to_uint32 SSH_FX_INVALID_HANDLE)
            in
            sshout
              (to_client SSH_FXP_STATUS
                 (Cstruct.concat [ uint32_to_cs id; payload ]))
            >>= fun () -> Lwt.return working_table
        | _ ->
            (* if the handle is already opened -> remove the handle entry in the hash table *)
            let _ = FS.path_of_handle root handle in
            (* FIXME: we always reply with status ok... *)
            let payload =
              uint32_to_cs (Sshfs_tag.sshfs_errcode_to_uint32 SSH_FX_OK)
            in
            sshout
              (to_client SSH_FXP_STATUS
                 (Cstruct.concat [ uint32_to_cs id; payload ]))
            >>= fun () ->
            Hashtbl.remove working_table handle;
            Lwt.return working_table)
    (* 6.4 Reading and Writing *)
    | SSH_FXP_WRITE ->
        (* TODO: what to do with the end of the file if we were asked to write in the middle of the file *)
        let handle_length =
          Int32.to_int (uint32_of_cs (Cstruct.sub data 4 4))
        in
        let handle = Cstruct.to_string (Cstruct.sub data 8 handle_length) in
        let offset = uint64_of_cs (Cstruct.sub data (8 + handle_length) 8) in
        let newdata_length =
          Int32.to_int
            (uint32_of_cs (Cstruct.sub data (8 + handle_length + 8) 4))
        in
        let newdata =
          Cstruct.sub data (8 + handle_length + 8 + 4) newdata_length
        in

        FS.path_of_handle root handle >>= fun path ->
        Log.debug (fun f ->
            f "[SSH_FXP_WRITE %ld] '%s' @%Ld (%d)\n%!" id path offset
              newdata_length);
        (* FIXME: we always reply with status ok... Deal with possible returned errors *)
        let offset = Int64.to_int offset in
        FS.write root path ~offset:(Optint.Int63.of_int offset) newdata_length newdata >>= fun _ ->
        let payload =
          uint32_to_cs (Sshfs_tag.sshfs_errcode_to_uint32 SSH_FX_OK)
        in
        sshout
          (to_client SSH_FXP_STATUS
             (Cstruct.concat [ uint32_to_cs id; payload ]))
        >>= fun () -> Lwt.return working_table
    (* Not implemented yet :) *)
    | _ ->
        Log.info (fun f -> f "[UNKNOWN id %ld (not implemented?)]\n%!" id);
        Cstruct.hexdump message;
        (let payload =
           Cstruct.concat
             [
               uint32_to_cs id;
               uint32_to_cs
                 (Sshfs_tag.sshfs_errcode_to_uint32 SSH_FX_OP_UNSUPPORTED);
             ]
         in
         sshout (to_client SSH_FXP_STATUS payload))
        >>= fun () -> Lwt.return working_table
end
