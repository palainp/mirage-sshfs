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

  module Chamelon = Kv.Make(B)(P)

  let fail pp e = Lwt.fail_with (Format.asprintf "%a" pp e)

  let fail_read = fail Chamelon.pp_error
  let fail_write = fail Chamelon.pp_write_error

  let (>>+=) m f = m >>= function
    | Error e -> fail_read e
    | Ok x    -> f x

  let (>>*=) m f = m >>= function
    | Error e -> fail_write e
    | Ok x    -> f x

  let connect disk =
    Chamelon.connect ~program_block_size:16 disk

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

  (* for now paths and handles are id but we can change that here *)
  let path_to_handle _ path =
    let handle = path in
    Lwt.return handle

  let path_of_handle _ handle =
    let path = handle in
    Lwt.return path

  (* silently discard the error if the key is absent *)
  let is_present root pathkey =
    Chamelon.exists root pathkey >>+= function
    | None -> Lwt.return false
    | (Some _) -> Lwt.return true

  let is_file root pathkey =
    Chamelon.exists root pathkey >>+= function
    | None -> Lwt.return false
    | (Some `Dictionary) -> Lwt.return false
    | (Some `Value) -> Lwt.return true

  let is_directory root pathkey =
    Chamelon.exists root pathkey >>+= function
    | None -> Lwt.return false
    | (Some `Dictionary) -> Lwt.return true
    | (Some `Value) -> Lwt.return false

  let remove_if_present root pathkey =
    is_present root pathkey >>= function
    | true ->
      Chamelon.remove root pathkey >>*= fun () -> Lwt.return_unit
    | false ->
      Lwt.return_unit

  let create_if_absent root pathkey =
    is_present root pathkey >>= function
    | true ->
      Lwt.return_unit
    | false ->
      Chamelon.set root pathkey "" >>*= fun () -> Lwt.return_unit

  let flush_file_if pflags root pathkey =
    if (pflags land (file_pflags_to_int SSH_FXF_TRUNC))==(file_pflags_to_int SSH_FXF_TRUNC) then begin 
      Log.debug (fun f -> f "[flush_file_if] SSH_FXF_TRUNC `%s`\n%!" (Mirage_kv.Key.to_string pathkey));
      remove_if_present root pathkey >>= fun () -> create_if_absent root pathkey
    end else
      Lwt.return_unit

  let create_file_if pflags root pathkey =
    if (pflags land (file_pflags_to_int SSH_FXF_CREAT))==(file_pflags_to_int SSH_FXF_CREAT) then begin
      Log.debug (fun f -> f "[create_file_if] SSH_FXF_CREAT `%s`\n%!" (Mirage_kv.Key.to_string pathkey));
      create_if_absent root pathkey
    end else
      Lwt.return_unit

  let touch_file_if pflags root pathkey =
    if ((pflags land (file_pflags_to_int SSH_FXF_APPEND))==(file_pflags_to_int SSH_FXF_APPEND)) then begin 
      Log.debug (fun f -> f "[touch_file_if] SSH_FXF_APPEND `%s`\n%!" (Mirage_kv.Key.to_string pathkey));
      create_if_absent root pathkey
    end else Lwt.return_unit

  let instruct_pflags pflags root path =
    let pathkey = Mirage_kv.Key.v path in
    flush_file_if pflags root pathkey >>= fun () ->
    create_file_if pflags root pathkey >>= fun () ->
    touch_file_if pflags root pathkey

  let read root path =
    let pathkey = Mirage_kv.Key.v path in
    Chamelon.get root pathkey >>+= fun data -> Lwt.return data

  let mtime root pathkey =
    Chamelon.last_modified root pathkey >>+= fun (d, ps) ->
    match Ptime.Span.of_d_ps (d, ps) with
      | None ->
        Lwt.return 0.0
      | Some span ->
        Lwt.return (Ptime.Span.to_float_s span)

  (* permissions:
   * p:4096, d:16384, -:32768
   * 256+128+64 : rwx for user
   * 32+16+8 : rwx for group
   * 4+2+1 : rws for others
   *)
  let permission root path =
    let pathkey = Mirage_kv.Key.v path in
    if (String.equal path "/") then (* permissions for / *)
      mtime root pathkey >>= fun time ->
      let payload = Cstruct.concat [
      Helpers.uint32_to_cs 5l ; (* SSH_FILEXFER_ATTR_SIZE(1) + ~SSH_FILEXFER_ATTR_UIDGID(2) + SSH_FILEXFER_ATTR_PERMISSIONS(4) + ~SSH_FILEXFER_ATTR_ACMODTIME(8) *)
      Helpers.uint64_to_cs 0L ; (* size value *)
      Helpers.uint32_to_cs (Int32.of_int(16384+448+56+7)) ; (* perm: drwxrwxrwx *)
      Helpers.uint32_to_cs (Int32.of_float time) ; (* atime *)
      Helpers.uint32_to_cs (Int32.of_float time)  (* mtime *)
      ] in
      Lwt.return (Sshfs_tag.SSH_FXP_ATTRS, payload)

    else (* path exists? and is a folder or a file? *)
      is_present root pathkey >>= function
      | false ->
          Lwt.return (Sshfs_tag.SSH_FXP_STATUS, Helpers.uint32_to_cs (Sshfs_tag.sshfs_errcode_to_uint32 Sshfs_tag.SSH_FX_NO_SUCH_FILE))
      | true ->
        mtime root pathkey >>= fun time ->
        is_file root pathkey >>= function
        | true -> (* This is a file *)
          Log.debug (fun f -> f "%s is a file\n%!" path);
          read root path >>= fun data ->
          let data = Cstruct.of_string data in
          let payload = Cstruct.concat [
          Helpers.uint32_to_cs 13l ; (* SSH_FILEXFER_ATTR_SIZE(1) + ~SSH_FILEXFER_ATTR_UIDGID(2) + SSH_FILEXFER_ATTR_PERMISSIONS(4) + SSH_FILEXFER_ATTR_ACMODTIME(8) *)
          Helpers.uint64_to_cs (Int64.of_int (Cstruct.length data)) ;
          Helpers.uint32_to_cs (Int32.of_int(32768+448+56+7)) ; (* perm: -rwxrwxrwx *)
          Helpers.uint32_to_cs (Int32.of_float time) ; (* atime *)
          Helpers.uint32_to_cs (Int32.of_float time)  (* mtime *)
          ] in
          Lwt.return (Sshfs_tag.SSH_FXP_ATTRS, payload)
        | false -> (* This is a folder *)
          Log.debug (fun f -> f "%s is a folder\n%!" path);
          let payload = Cstruct.concat [
          Helpers.uint32_to_cs 13l ; (* SSH_FILEXFER_ATTR_SIZE(1) + ~SSH_FILEXFER_ATTR_UIDGID(2) + SSH_FILEXFER_ATTR_PERMISSIONS(4) + SSH_FILEXFER_ATTR_ACMODTIME(8) *)
          Helpers.uint64_to_cs 10L ; (* !!FIXME!! size value *)
          Helpers.uint32_to_cs (Int32.of_int(16384+448+56+7)) ; (* perm: drwxrwxrwx *)
          Helpers.uint32_to_cs (Int32.of_float time) ; (* atime *)
          Helpers.uint32_to_cs (Int32.of_float time)  (* mtime *)
          ] in
          Lwt.return (Sshfs_tag.SSH_FXP_ATTRS, payload)

  (**
   pre: path is the key for [data(0..data_length-1)]
   post: path is the key for
       [data(0..offset-1), newdata(offset..offset+newdata_length-1), data(offset+newdata_length..data_length-1)]
       Q: take care when data_length < offset
       Q: take care when offset < 0
   *)
  let write root path offset newdata_length newdata =
    let pathkey = Mirage_kv.Key.v path in
    Chamelon.get root pathkey >>= begin function
    | Error _ -> Lwt.return_unit
    | Ok data ->
       let data = Cstruct.of_string data in
       let data_length = Cstruct.length data in

       let offset_before = max 0 (Int64.to_int offset) in
       let len_before = min data_length offset_before in
       let before = Cstruct.sub data 0 len_before in

       let offset_after = min ((Int64.to_int offset)+newdata_length) data_length in
       let len_after = max 0 (data_length-offset_after) in
       let after = Cstruct.sub data offset_after len_after in

       let newdata = Cstruct.concat [before; newdata; after] in
       (* FIXME: is there a way to update a key ? *)
       Chamelon.remove root pathkey >>*= fun () ->
       Chamelon.set root pathkey (Cstruct.to_string newdata) >>*= fun () ->
       Lwt.return_unit
    end

  (* TODO: deal remove directories... *)
  let remove root path =
    let pathkey = Mirage_kv.Key.v path in
    Chamelon.remove root pathkey

  (* TODO: deal rename directories... *)
  let rename root oldpath newpath =
    let oldpathkey = Mirage_kv.Key.v oldpath in
    let newpathkey = Mirage_kv.Key.v newpath in
    remove_if_present root newpathkey >>= fun() ->
    Chamelon.get root oldpathkey >>+= fun data ->
    Chamelon.set root newpathkey data >>*= fun () ->
    Chamelon.remove root oldpathkey >>*= fun () ->
    Lwt.return_unit

  (* TODO: do not shows up the . file as it's only used to create directories *)
  let lsdir root path =
    let pathkey = Mirage_kv.Key.v path in
    Chamelon.list root pathkey >>+= fun res -> Lwt.return res

  let mkdir root path =
    (* it seems that we cannot create empty directory, so I try to add a empty . file which must
       be returned when lsidr is called *)
    let dummy = (String.concat "/" [path; "."]) in
    let dummykey = Mirage_kv.Key.v dummy in
    Chamelon.set root dummykey ""

end
