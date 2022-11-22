(* version 3 used by openssh : https://filezilla-project.org/specs/draft-ietf-secsh-filexfer-02.txt *)

(*

  4bytes errcodes of message

  	#define SSH_FX_FAILURE                       4
  	#define SSH_FX_BAD_MESSAGE                   5
  	#define SSH_FX_NO_CONNECTION                 6
  	#define SSH_FX_CONNECTION_LOST               7
  	#define SSH_FX_OP_UNSUPPORTED                8

  *)
type sshfs_errcode =
  | SSH_FX_OK
  | SSH_FX_EOF
  | SSH_FX_NO_SUCH_FILE
  | SSH_FX_PERMISSION_DENIED
  | SSH_FX_INVALID_HANDLE
  | SSH_FX_NO_SUCH_PATH
  | SSH_FX_FILE_IS_A_DIRECTORY
  | SSH_FX_OP_UNSUPPORTED

let sshfs_errcode_to_uint32 = function
  | SSH_FX_OK -> 0l
  | SSH_FX_EOF -> 1l
  | SSH_FX_NO_SUCH_FILE -> 2l
  | SSH_FX_PERMISSION_DENIED -> 3l
  | SSH_FX_INVALID_HANDLE -> 9l
  | SSH_FX_NO_SUCH_PATH -> 10l
  | SSH_FX_FILE_IS_A_DIRECTORY -> 24l
  | SSH_FX_OP_UNSUPPORTED -> 31l

(*1 byte type of messages
  | SSH_FXP_REALPATH           16
  | SSH_FXP_STAT               17
  | SSH_FXP_READLINK           19
  | SSH_FXP_LINK               21
  | SSH_FXP_BLOCK              22
  | SSH_FXP_UNBLOCK            23

  | SSH_FXP_EXTENDED          200
  | SSH_FXP_EXTENDED_REPLY    201
*)

type sshfs_packtype =
  | SSH_FXP_INIT
  | SSH_FXP_VERSION
  | SSH_FXP_OPEN
  | SSH_FXP_CLOSE
  | SSH_FXP_READ
  | SSH_FXP_WRITE
  | SSH_FXP_LSTAT
  | SSH_FXP_FSTAT
  | SSH_FXP_SETSTAT
  | SSH_FXP_FSETSTAT
  | SSH_FXP_OPENDIR
  | SSH_FXP_READDIR
  | SSH_FXP_REMOVE
  | SSH_FXP_MKDIR
  | SSH_FXP_RMDIR
  | SSH_FXP_RENAME
  | SSH_FXP_STATUS
  | SSH_FXP_HANDLE
  | SSH_FXP_DATA
  | SSH_FXP_NAME
  | SSH_FXP_ATTRS
  | UNDEF_SSHFS_PACKTYPE

let sshfs_packtype_of_uint8 = function
  | 1 -> SSH_FXP_INIT
  | 2 -> SSH_FXP_VERSION
  | 3 -> SSH_FXP_OPEN
  | 4 -> SSH_FXP_CLOSE
  | 5 -> SSH_FXP_READ
  | 6 -> SSH_FXP_WRITE
  | 7 -> SSH_FXP_LSTAT
  | 8 -> SSH_FXP_FSTAT
  | 9 -> SSH_FXP_SETSTAT
  | 10 -> SSH_FXP_FSETSTAT
  | 11 -> SSH_FXP_OPENDIR
  | 12 -> SSH_FXP_READDIR
  | 13 -> SSH_FXP_REMOVE
  | 14 -> SSH_FXP_MKDIR
  | 15 -> SSH_FXP_RMDIR
  | 18 -> SSH_FXP_RENAME
  | 101 -> SSH_FXP_STATUS
  | 102 -> SSH_FXP_HANDLE
  | 103 -> SSH_FXP_DATA
  | 104 -> SSH_FXP_NAME
  | 105 -> SSH_FXP_ATTRS
  | _ -> UNDEF_SSHFS_PACKTYPE

let sshfs_packtype_to_uint8 = function
  | SSH_FXP_INIT -> 1
  | SSH_FXP_VERSION -> 2
  | SSH_FXP_OPEN -> 3
  | SSH_FXP_CLOSE -> 4
  | SSH_FXP_READ -> 5
  | SSH_FXP_WRITE -> 6
  | SSH_FXP_LSTAT -> 7
  | SSH_FXP_FSTAT -> 8
  | SSH_FXP_SETSTAT -> 9
  | SSH_FXP_FSETSTAT -> 10
  | SSH_FXP_OPENDIR -> 11
  | SSH_FXP_READDIR -> 12
  | SSH_FXP_REMOVE -> 13
  | SSH_FXP_MKDIR -> 14
  | SSH_FXP_RMDIR -> 15
  | SSH_FXP_RENAME -> 18
  | SSH_FXP_STATUS -> 101
  | SSH_FXP_HANDLE -> 102
  | SSH_FXP_DATA -> 103
  | SSH_FXP_NAME -> 104
  | SSH_FXP_ATTRS -> 105
  | _ -> 0
