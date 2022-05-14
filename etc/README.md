# auto sshfs

In order to use this unikernel with autofs, you should:
* install your distribution's `autofs+sshfs` packages
* edit the `/etc/auto.master` file to add something like
```
/mnt/sshfs /etc/auto.sshfs uid=1000,gid=1000,--timeout=30,--ghost
```
and adapt your uid/gid
* add a new `/etc/auto.sshfs` file:
```
local -fstype=fuse,allow_other,port=22022,IdentityFile=/path/to/keyfile :sshfs\#username@127.0.0.1:/
```
and adapt the running port, the path for the private key and the
ssh username.
* start the autofs service

Note that the keyfile must be owned by root (or the user running
the autofs daemon), and must have the `rw-------` (600) permissions
otherwise ssh may consider that the keyfile is not safe enough.

Also note that root must accept the server fingerprint prior any
autofs connexion, the easiest way to do that is to connect to the
server a first time before using autofs.
Another, discouraged, option can be to add `StrictHostKeycheing=no`
in the `auto.sshfs` file.

This will automount the block when you move to `/mnt/sshfs/local`
and unmount it after a desired timeout.
You still have to manually start the SSHFS server with the command
line provided in the main `README.md`.
