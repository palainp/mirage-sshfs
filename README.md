# mirage-sshfs

[mirage-sshfs](https://github.com/palainp/mirage-sshfs) is an
_ISC-licensed_ SSHFS server implementation in ocaml.

This unikernel can be seen as a "super chrooted" SSHFS mount
point or be used as a VM that provides a common disk for other
VMs.

## Filesystem creation
In order to use the unikernel, you must create a disk file that
will be shared with SSHFS. It currently uses a FAT16 ocaml
implementation. The following create a disk image and add a
file in it, feel free to add any file you want (the pubkey must
be present at the root of the filesystem and must be `username.pub`).
```
ssh-keygen -t rsa -C mirage_sshfs -f mirage -N '' && \
chmod 600 mirage && \
opam install fat-filesystem -y && \
fat create disk.img && \
fat add disk.img mirage.pub
```

Any kind of filesystem should be ok to use as it will be seen on the
client side via the sshfs protocol. We just have to be able to add
the first public key to connect against.

## Unix "chrooted" SSHFS
```
mirage configure -t unix &&
make depend &&
make &&
mirage_sshfs --port 22022 --user mirage
```

The server gives access to the content of the `disk.img`
file with the user `mirage` and the key is in
`disk.img/mirage.pub`. The default values for port and
username are `18022` and `mirage`.

You can connect to it with the sshfs mount command:
```
sshfs mirage@hostserver:/ \
  /path/mount/ \
  -p 22022 \
  -o IdentityFile=/absolute/path/to/mirage && \
ls -l /path/mount/ && \
cat /path/mount/mirage.pub
```

## Xen sshfs VM
```
mirage configure -t xen &&
make depend &&
make
```
