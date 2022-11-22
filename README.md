# mirage-sshfs

Warning: WIP!

[mirage-sshfs][] is an _ISC-licensed_ SSHFS server implementation in ocaml.

This unikernel can be seen as a "super chrooted" SSHFS mount point or be
used as a VM that provides a common disk for other VMs.

## Public/Private key access
As we use ssh for communication, we first need to have a public/private key pair.
We will later add the public key to the disk image file (the pubkey must be
present at the root of the filesystem or must be given to the unikernel through
the `--user` and `--key` options).
```
ssh-keygen -t ed25519 -C mirage_sshfs -f username -N '' && \
chmod 600 username
```
Note that the empty passphrase is not mandatory (it's currently not supported by
[awa-ssh]() but the passphrase will be supported by the sshfs client).

## Filesystem creation
This unikernel can be used with persistent (but that's not mandatory if you
want to simply share some files) storage layer.

### Not persistent storage layer
If you don't want to have persistent data, you can modify `src/config.ml` to
comment out the section talking about `chamelon` and `aes-ccm`, and simply use
```
let my_fs = kv_rw_mem ()
```

In this case, you must add the `--key 'ssh-ed25519\ AAAA....xyz\ mirage_sshfs` for
starting the server and defining the `--user` public key.

### Persistent storage layer
If you prefer to save data persistently, you must create a disk file that will be
shared with SSHFS. It currently uses a [chamelon][] Ocaml implementation of
[littlefs][].

```
opam install chamelon-unix -y && \
dd if=/dev/zero of=disk.img bs=1M count=32 && \
chamelon format disk.img 512
```

Any kind of filesystem should be ok to use as it will be seen on the client
side via the sshfs protocol. In the previous instructions, we also add the public
key at the root of the filesystem in order to be able to connect without having to
use the `--key` option.

## Filesystem encryption layer
If you want to use an enryption layer under the filesystem's structure, this
unikernel uses the AES-CCM encrypted [mirage-block-ccm][] storage. You may
want to convert an non-encrypted image (as the one previously created) to an
encrypted one with the following:
```
opam install mirage-block-ccm -y && \
ccmblock enc --in=disk.img --out=encrypted.img --key=1234567890ABCDEF1234567890ABCDEF
```

In this case, you must add the `--aes-ccm-key 1234567890ABCDEF1234567890ABCDEF` in
the commands and use the encrypted image file.

## The User/Key database
You can specify users and public keys with any one of the following methods. The user
database is constructed in such a way that a user account cannot be redefined. So
there is a priority in taking users into account:
- command line option,
- then `*.pub` files at the root level of the KV store,
- then `authorized_keys` at the root level of the KV store.

Of course you can add users and public keys when the unikernel is alive and you may
only need one of the following method to add your first user (in particular when using
`kv_mem` backend for storage).

### As a command line option
The first way is to use the `--user` and `--key` command line option. The easiest way
to do that is the following:
```
./src/dist/mirage_sshfs --user username --key "$(cat username.pub | sed 's/ /\\ /g')"
```

### With public key files at the root of the KV store
You can add any public key file at the root level of the KV store, for example with
chamelon you can do this:
```
chamelon write ./disk.img 512 /username.pub "$(cat username.pub)"
```

### With an authorized_keys file at the root of the KV store
You can add an `authorized_keys` file at the root level as you can do with an ssh server:
```
chamelon write ./disk.img 512 /authorized_keys "$(cat ~/.ssh/authorized_keys)"
```

## Running Unix "chrooted" SSHFS
```
mirage configure -t unix -f src/config.ml && \
make depend && \
dune build && \
./src/dist/mirage_sshfs --port 22022 --user username --seed 111213
```

The server gives access to the content of the mirage-kv store with the user
`username` and a key associated with that user (as defined on the command line
with option `--key` or at the root level `disk.img/username.pub` or in
`disk.img/authorized_keys`). The default values for port and username are
`18022` and `mirage`, the default key is not a valid publickey and cannot be used.

## Running Hvt SSHFS VM
```
mirage configure -t hvt -f src/config.ml && \
make depend && \
dune build
```

You have to set up the solo5-hvt environment as described in the [solo5][]
setup page. Then you can run the unikernel with solo5:
```
solo5-hvt --net:service=tap100 \
  --block:storage=disk.img \
  ./src/dist/mirage_sshfs.hvt \
  --port 22022 --user username --seed 111213
```

## Running Qubes SSHFS VM
```
mirage configure -t qubes -f src/config.ml && \
make depend && \
dune build
```

To create a VM using the new unikernel, you can run the following commands in
`dom0`. Here `mirage-sshfs` stands for the name of your new VM, `dev_VM` for
the name of the VM in which you compile your unikernel.

You can look into qubes-test-mirage to upload your unikernel to `dom0`
[qubes-test-mirage][].

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

And finally you will have to add rules in your connecting firewall VM to
support communication between the unikernel_sshfs VM and your clients VMs.

## Connecting to the unikernel

Once the server is running, you can mount the disk with the sshfs command:
```
sshfs username@hostserver:/ \
  /path/mount/ \
  -p 22022 \
  -o IdentityFile=/absolute/path/to/username && \
ls -l /path/mount/ && \
cat /path/mount/username.pub
```

## (Auto-)Connecting to the unikernel

See `etc/README.md`.

[mirage-sshfs]: https://github.com/palainp/mirage-sshfs
[awa-ssh]: https://github.com/mirage/awa-ssh
[chamelon]: https://github.com/yomimono/chamelon/
[littlefs]: https://github.com/littlefs-project/littlefs
[mirage-block-ccm]: https://github.com/sg2342/mirage-block-ccm
[solo5]: https://github.com/Solo5/solo5/blob/master/docs/building.md#setting-up
[qubes-test-mirage]: https://github.com/talex5/qubes-test-mirage
