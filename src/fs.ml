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
open Helpers
open Sshfs_tag

module Make (KV: Mirage_kv.RW) (P: Mirage_clock.PCLOCK) = struct

  let log_src = Logs.Src.create "sshfs_fs" ~doc:"Helper fs functions"
  module Log = (val Logs.src_log log_src : Logs.LOG)

  let fail pp e = Lwt.fail_with (Format.asprintf "%a" pp e)

  let fail_read = fail KV.pp_error
  let fail_write = fail KV.pp_write_error

  let (>>+=) m f = m >>= function
    | Error e -> fail_read e
    | Ok x    -> f x

  let (>>*=) m f = m >>= function
    | Error e -> fail_write e
    | Ok x    -> f x

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
    KV.exists root pathkey >>+= function
    | None -> Lwt.return false
    | (Some _) -> Lwt.return true

  let is_file root pathkey =
    KV.exists root pathkey >>+= function
    | None -> Lwt.return false
    | (Some `Dictionary) -> Lwt.return false
    | (Some `Value) -> Lwt.return true

  let is_directory root pathkey =
    KV.exists root pathkey >>+= function
    | None -> Lwt.return false
    | (Some `Dictionary) -> Lwt.return true
    | (Some `Value) -> Lwt.return false

  let remove_if_present root pathkey =
    is_present root pathkey >>= function
    | true ->
      KV.remove root pathkey >>*= fun () -> Lwt.return_unit
    | false ->
      Lwt.return_unit

  let create_if_absent root pathkey =
    is_present root pathkey >>= function
    | true ->
      Lwt.return_unit
    | false ->
      KV.set root pathkey "" >>*= fun () -> Lwt.return_unit

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

  let mtime root pathkey =
    KV.last_modified root pathkey >>+= fun (d, ps) ->
    match Ptime.Span.of_d_ps (d, ps) with
      | None ->
        Lwt.return 0.0
      | Some span ->
        Lwt.return (Ptime.Span.to_float_s span)

  let size_key root pathkey =
    KV.size root pathkey >>= function
    | Error _ -> Lwt.return 0
    | Ok s -> Lwt.return s

  let size root path =
    let pathkey = Mirage_kv.Key.v path in
    size_key root pathkey

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
      size_key root pathkey >>= fun s ->
      let payload = Cstruct.concat [
      uint32_to_cs 5l ; (* SSH_FILEXFER_ATTR_SIZE(1) + ~SSH_FILEXFER_ATTR_UIDGID(2) + SSH_FILEXFER_ATTR_PERMISSIONS(4) + ~SSH_FILEXFER_ATTR_ACMODTIME(8) *)
      uint64_to_cs (Int64.of_int s) ; (* size value *)
      uint32_to_cs (Int32.of_int(16384+448+56+7)) ; (* perm: drwxrwxrwx *)
      uint32_to_cs (Int32.of_float time) ; (* atime *)
      uint32_to_cs (Int32.of_float time)  (* mtime *)
      ] in
      Lwt.return (SSH_FXP_ATTRS, payload)

    else (* path exists? and is a folder or a file? *)
      is_present root pathkey >>= function
      | false ->
          Lwt.return (SSH_FXP_STATUS, uint32_to_cs (sshfs_errcode_to_uint32 SSH_FX_NO_SUCH_FILE))
      | true ->
        mtime root pathkey >>= fun time ->
        is_file root pathkey >>= function
        | true -> (* This is a file *)
          size_key root pathkey >>= fun s ->
          let payload = Cstruct.concat [
          uint32_to_cs 13l ; (* SSH_FILEXFER_ATTR_SIZE(1) + ~SSH_FILEXFER_ATTR_UIDGID(2) + SSH_FILEXFER_ATTR_PERMISSIONS(4) + SSH_FILEXFER_ATTR_ACMODTIME(8) *)
          uint64_to_cs (Int64.of_int s) ;
          uint32_to_cs (Int32.of_int(32768+448+56+7)) ; (* perm: -rwxrwxrwx *)
          uint32_to_cs (Int32.of_float time) ; (* atime *)
          uint32_to_cs (Int32.of_float time)  (* mtime *)
          ] in
          Lwt.return (SSH_FXP_ATTRS, payload)
        | false -> (* This is a folder *)
          size_key root pathkey >>= fun s ->
          let payload = Cstruct.concat [
          uint32_to_cs 13l ; (* SSH_FILEXFER_ATTR_SIZE(1) + ~SSH_FILEXFER_ATTR_UIDGID(2) + SSH_FILEXFER_ATTR_PERMISSIONS(4) + SSH_FILEXFER_ATTR_ACMODTIME(8) *)
          uint64_to_cs (Int64.of_int s) ;
          uint32_to_cs (Int32.of_int(16384+448+56+7)) ; (* perm: drwxrwxrwx *)
          uint32_to_cs (Int32.of_float time) ; (* atime *)
          uint32_to_cs (Int32.of_float time)  (* mtime *)
          ] in
          Lwt.return (SSH_FXP_ATTRS, payload)

  let read_key root pathkey ~offset ~length =
   KV.get_partial root pathkey ~offset ~length >>= function
     | Error e -> Lwt.return (Error e)
     | Ok data -> Lwt.return (Ok data)

  let read root path ~offset ~length =
    let pathkey = Mirage_kv.Key.v path in
    read_key root pathkey ~offset ~length

  (**
   pre: path is the key for [data(0..data_length-1)]
   post: path is the key for
       [data(0..offset-1), newdata(offset..offset+newdata_length-1), data(offset+newdata_length..data_length-1)]
       Q: take care when data_length < offset
       Q: take care when offset < 0
   *)
  let write root path ~offset _newdata_length newdata =
    let pathkey = Mirage_kv.Key.v path in
    let data = Cstruct.to_string newdata in
    KV.set_partial root pathkey ~offset data

  (* TODO: deal remove directories... *)
  let remove root path =
    let pathkey = Mirage_kv.Key.v path in
    KV.remove root pathkey

  (* TODO: deal rename directories... *)
  let rename root oldpath newpath =
    let source = Mirage_kv.Key.v oldpath in
    let dest = Mirage_kv.Key.v newpath in
    KV.rename root ~source ~dest

  (* TODO: do not shows up the . file as it's only used to create directories *)
  let lsdir root path =
    let pathkey = Mirage_kv.Key.v path in
    KV.list root pathkey >>+= fun res -> Lwt.return res

  let mkdir root path =
    (* it seems that we cannot create empty directory, so I try to add a empty . file which must
       be returned when lsidr is called *)
    let dummy = (String.concat "/" [path; "."]) in
    let dummykey = Mirage_kv.Key.v dummy in
    KV.set root dummykey ""

end
