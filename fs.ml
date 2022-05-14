(*
 * Copyright (c) 2022 Pierre Alain <pierre.alain@tuta.io>
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

module Make (B: Mirage_block.S) (P: Mirage_clock.PCLOCK) = struct

  let log_src = Logs.Src.create "sshfs_fs" ~doc:"Helper fs functions"
  module Log = (val Logs.src_log log_src : Logs.LOG)

  module KV = Kv.Make(B)(P)

  let fail fmt = Fmt.kstr Lwt.fail_with fmt

  let (>>*=) m f = m >>= function
    | Error e -> fail "%a" KV.pp_write_error (e :> KV.write_error)
    | Ok x    -> f x

  let connect disk =
    KV.connect ~program_block_size:16 disk

  type file_pflags =
    | SSH_FXF_READ
    | SSH_FXF_WRITE
    | SSH_FXF_APPEND
    | SSH_FXF_CREAT
    | SSH_FXF_TRUNC
    | SSH_FXF_EXCL
    | SSH_FXF_UNDEF

  let file_pflags_of_int = function
    | 0x00000001 -> SSH_FXF_READ
    | 0x00000002 -> SSH_FXF_WRITE
    | 0x00000004 -> SSH_FXF_APPEND
    | 0x00000008 -> SSH_FXF_CREAT
    | 0x00000010 -> SSH_FXF_TRUNC
    | 0x00000020 -> SSH_FXF_EXCL
    | _ -> SSH_FXF_UNDEF

  let file_pflags_to_int = function
    | SSH_FXF_READ -> 0x00000001
    | SSH_FXF_WRITE -> 0x00000002
    | SSH_FXF_APPEND -> 0x00000004
    | SSH_FXF_CREAT -> 0x00000008
    | SSH_FXF_TRUNC -> 0x00000010
    | SSH_FXF_EXCL -> 0x00000020
    | SSH_FXF_UNDEF -> 0

  (* gives the content of a file, this is used by the ssh server to key the public keys *)
  let get_file_data root filename =
    KV.get root @@ Mirage_kv.Key.v filename >|= function
    | Error e ->
        Log.warn (fun f -> f "*** accessing file %s with error %a\n%!" filename KV.pp_error e);
        Cstruct.create 0
    | Ok content ->
        Log.debug (fun f -> f "*** file %s have content : '%s'\n%!" filename content);
        Cstruct.of_string content

  (* for now paths and handles are id but we can change that here *)
  let path_to_handle _ path =
    let handle = path in
    Lwt.return handle

  let path_of_handle _ handle =
    let path = handle in
    Lwt.return path

  let is_present root path =
    KV.exists root @@ Mirage_kv.Key.v path >|= function
    | Error _ -> false
    | Ok _ -> true

  (* silently discard the error if the key is absent *)
  let remove_if_present root path =
    KV.remove root @@ Mirage_kv.Key.v path >>*= fun () -> Lwt.return_unit

  (* silently discard the error if the key is absent *)
  let create_if_absent root path =
    let pathkey = Mirage_kv.Key.v path in
    KV.set root pathkey "" >>*= fun () -> Lwt.return_unit

  let flush_file_if pflags root path =
    if (pflags land (file_pflags_to_int SSH_FXF_TRUNC))==(file_pflags_to_int SSH_FXF_TRUNC) then begin 
      Log.debug (fun f -> f "[flush_file_if] SSH_FXF_TRUNC `%s`\n%!" path);
      remove_if_present root path >>= fun () -> create_if_absent root path
    end else
      Lwt.return_unit

  let create_file_if pflags root path =
    if (pflags land (file_pflags_to_int SSH_FXF_CREAT))==(file_pflags_to_int SSH_FXF_CREAT) then begin
      Log.debug (fun f -> f "[create_file_if] SSH_FXF_CREAT `%s`\n%!" path);
      create_if_absent root path
    end else
      Lwt.return_unit

  let touch_file_if pflags root path =
    if ((pflags land (file_pflags_to_int SSH_FXF_APPEND))==(file_pflags_to_int SSH_FXF_APPEND)) then begin 
      Log.debug (fun f -> f "[touch_file_if] SSH_FXF_APPEND `%s`\n%!" path);
      create_if_absent root path
    end else Lwt.return_unit

  (* permissions:
   * p:4096, d:16384, -:32768
   * 256+128+64 : rwx for user
   * 32+16+8 : rwx for group
   * 4+2+1 : rws for others
   *)
  let permission root path =
    let path = Mirage_kv.Key.v path in
    if (String.equal (Mirage_kv.Key.to_string path) "/") then (* permissions for / *)
      let payload = Cstruct.concat [
      Helpers.uint32_to_cs 5l ; (* SSH_FILEXFER_ATTR_SIZE(1) + ~SSH_FILEXFER_ATTR_UIDGID(2) + SSH_FILEXFER_ATTR_PERMISSIONS(4) + ~SSH_FILEXFER_ATTR_ACMODTIME(8) *)
      Helpers.uint64_to_cs 0L ; (* size value *)
      Helpers.uint32_to_cs (Int32.of_int(16384+448+56+7)) ; (* perm: drwxrwxrwx *)] in
      Lwt.return (Sshfs_tag.SSH_FXP_ATTRS, payload)

    else (* path exists? and is a folder or a file? *)
      KV.exists root path >>= begin function
      | Error e ->
          Log.debug (fun f -> f "*** get permissions for file %s error: %a\n%!" (Mirage_kv.Key.to_string path) KV.pp_error e);
          Lwt.return (Sshfs_tag.SSH_FXP_STATUS, Helpers.uint32_to_cs (Sshfs_tag.sshfs_errcode_to_uint32 Sshfs_tag.SSH_FX_NO_SUCH_FILE))
      | Ok _ ->
          KV.list root path >>= begin function
          | Error _ -> (* This key does NOT contains anything: it's a file *)
              Log.debug (fun f -> f "%s is a file\n%!" (Mirage_kv.Key.to_string path));
              KV.get root path >>= begin function
              | Error _ ->
                  Lwt.return (Sshfs_tag.SSH_FXP_STATUS, Helpers.uint32_to_cs (Sshfs_tag.sshfs_errcode_to_uint32 Sshfs_tag.SSH_FX_NO_SUCH_FILE))
              | Ok data ->
                  let data = Cstruct.of_string data in
                  let payload = Cstruct.concat [
                  Helpers.uint32_to_cs 5l ; (* SSH_FILEXFER_ATTR_SIZE(1) + ~SSH_FILEXFER_ATTR_UIDGID(2) + SSH_FILEXFER_ATTR_PERMISSIONS(4) + ~SSH_FILEXFER_ATTR_ACMODTIME(8) *)
                  Helpers.uint64_to_cs (Int64.of_int (Cstruct.length data)) ; (* !!FIXME!! size value *)
                  Helpers.uint32_to_cs (Int32.of_int(32768+448+56+7)) ; (* perm: -rwxrwxrwx *)] in
                  Lwt.return (Sshfs_tag.SSH_FXP_ATTRS, payload)
              end
          | Ok _ -> (* This key does contains something: it's a folder *)
              Log.debug (fun f -> f "%s is a folder\n%!" (Mirage_kv.Key.to_string path));
              let payload = Cstruct.concat [
              Helpers.uint32_to_cs 5l ; (* SSH_FILEXFER_ATTR_SIZE(1) + ~SSH_FILEXFER_ATTR_UIDGID(2) + SSH_FILEXFER_ATTR_PERMISSIONS(4) + ~SSH_FILEXFER_ATTR_ACMODTIME(8) *)
              Helpers.uint64_to_cs 10L ; (* !!FIXME!! size value *)
              Helpers.uint32_to_cs (Int32.of_int(16384+448+56+7)) (* perm: drwxrwxrwx *)] in
              Lwt.return (Sshfs_tag.SSH_FXP_ATTRS, payload)
          end
       end

  (* TODO: do not shows up the . file as it's only used to create directories *)
  let lsdir root path =
    KV.list root @@ Mirage_kv.Key.v path >|= function
    | Error _ -> []
    | Ok res -> res

  let read root path = 
    KV.get root @@ Mirage_kv.Key.v path >>= function
    | Error e ->
      Log.debug (fun f -> f "*** read for file %s error: %a\n%!" path KV.pp_error e);
      Lwt.return ""
    | Ok data -> Lwt.return data

  let write root path offset newdata_length newdata =
    let pathkey = Mirage_kv.Key.v path in
    KV.get root pathkey >>= begin function
    | Error _ -> Lwt.return_unit
    | Ok data ->
       let data = Cstruct.of_string data in
       let data_length = Cstruct.length data in

       let offset_before = max 0 ((Int64.to_int offset)-1) in
       let len = min data_length offset_before in
       let before = Cstruct.sub data 0 len in

       let offset_after = min ((Int64.to_int offset)+newdata_length) data_length in
       let after = Cstruct.sub data offset_after (data_length-len) in

       let newdata = Cstruct.concat [before; newdata; after] in
       KV.set root pathkey (Cstruct.to_string newdata) >>*= fun () ->
       Lwt.return_unit
    end

  let remove root path =
    KV.remove root @@ Mirage_kv.Key.v path

  (* TODO: deal with renaming of directories... *)
  let rename root oldpath newpath =
    let oldpathkey = Mirage_kv.Key.v oldpath in
    let newpathkey = Mirage_kv.Key.v newpath in
    KV.get root oldpathkey >>= begin function
    | Error _ -> Lwt.return_unit
    | Ok data ->
        KV.set root newpathkey data >>*= fun () ->
        KV.remove root oldpathkey >>*= fun () ->
        Lwt.return_unit
    end

  let mkdir root path =
    (* it seems that we cannot create empty directory, so I try to add a empty . file which must
       be returned when lsidr is called *)
    let dummy = (String.concat "/" [path; "."]) in
    let dummykey = Mirage_kv.Key.v dummy in
    KV.set root dummykey ""

end