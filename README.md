# mirage-sshfs

Warning: WIP, in order to compile and execute, you will have to:
```
opam pin fat-filesystem git+https://github.com/palainp/ocaml-fat -y
```

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
ssh-keygen -t ed25519 -C mirage_sshfs -f username -N '' && \
chmod 600 username && \
opam install fat-filesystem -y && \
fat create disk.img && \
fat add disk.img username.pub
```

Any kind of filesystem should be ok to use as it will be seen on the
client side via the sshfs protocol. We just have to be able to add
the first public key to connect against.

## Filesystem encryption layer
If you want to use an enryption layer under the filesystem's structure,
this unikernel uses the AES-CCM encrypted `mirage-block-ccm` storage.
You may want to convert an non-encrypted image (as the one previously
created) to an encrypted one with the following:
```
opam install mirage-block-ccm -y && \
ccmblock enc --in=disk.img --out=encrypted.img --key=1234567890ABCDEF1234567890ABCDEF
```

In this case, you must add the `--blockkey 1234567890ABCDEF1234567890ABCDEF`
in the following commands and use the encrypted image file.

## Running Unix "chrooted" SSHFS
```
mirage configure -t unix && \
make depend && \
make && \
mirage_sshfs --port 22022 --user username --seed 111213
```

The server gives access to the content of the `disk.img`
file with the user `username` and the key is in
`disk.img/username.pub`. The default values for port and
username are `18022` and `mirage`.

## Running Hvt SSHFS VM
```
mirage configure -t hvt && \
make depend && \
make
```

You have to set up the solo5-hvt environment as described in the
[solo5 setup page](https://github.com/Solo5/solo5/blob/master/docs/building.md#setting-up).
Then you can run the unikernel with solo5:
```
solo5-hvt --net:service=tap100 \
  --block:storage=disk.img \
  mirage_sshfs.hvt \
  --port 22022 --user username --seed 111213
```

## Running Qubes SSHFS VM
```
mirage configure -t qubes && \
make depend && \
make
```

To create a VM using the new unikernel, you can run the following commands in `dom0`.
Here `mirage-sshfs` stands for the name of your new VM, `dev_VM` for the name of the
VM in which you compile your unikernel.

You can look into qubes-test-mirage to upload your unikernel to `dom0`
[qubes-test-mirage](https://github.com/talex5/qubes-test-mirage).

```
qvm-create \
  --property kernel=mirage-sshfs \
  --property kernelopts='' \
  --property memory=32 \
  --property maxmem=32 \
  --property netvm=sys-firewall \
  --property provides_network=False \
  --property vcpus=1 \
  --property virt_mode=pvh \
  --label=gray \
  --standalone \
  mirage-sshfs

qvm-features mirage-sshfs no-default-kernelopts 1
qvm-run -p dev_VM 'cat /path/to/mirage-sshfs/disk.img' > /home/user/Desktop/disk.img
qvm-volume import mirage-sshfs:private /home/user/Desktop/disk.img
qvm-prefs -- mirage-sshfs kernelopts '--seed 111213'
```

If you want to enable debug tracing, you can also run:
```
qvm-prefs -- mirage-sshfs kernelopts '-l "*:debug" --seed 111213'
```

And finally you will have to add rules in your connecting firewall VM to support
communication between the unikernel_sshfs VM and your clients VMs.

## Connecting to the unikernel

Once the server is running, you can mount the disk with the sshfs
command:
```
sshfs username@hostserver:/ \
  /path/mount/ \
  -p 22022 \
  -o IdentityFile=/absolute/path/to/username && \
ls -l /path/mount/ && \
cat /path/mount/username.pub
```
