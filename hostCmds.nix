{ pkgs ? import <nixpkgs> { }, targetSystem ? "aarch64-linux" }:

let
  inherit (pkgs.lib) getExe getBin;

  targetPkgs = import <nixpkgs> { system = targetSystem; };
  recoveryEnv = import ./recoveryEnv.nix { inherit targetPkgs; };

  prefix = "/data/local/tmp/nix-chroot";
in

rec {
  enterScript = pkgs.writeScript "enter" ''
    #!/bin/sh

    for dir in proc data ; do
      mkdir -p ${prefix}/$dir

      # Don't bind again if it's already mounted
      if ! grep ${prefix}/$dir /proc/mounts > /dev/null ; then
        mount -o bind /$dir ${prefix}/$dir
      fi
    done

    PATH=/nix/var/nix/profiles/default/bin:$PATH chroot ${prefix} bash

    ${prefix}/cleanup
  '';

  cleanupScript = pkgs.writeScript "cleanup" ''
    #!/bin/sh

    for dir in ${prefix}/* ; do
      if grep $dir /proc/mounts > /dev/null ; then
        umount $dir
      fi
    done
  '';

  removalScript = pkgs.writeScript "remove" ''
    #!/bin/sh
    ${prefix}/cleanup

    if grep ${prefix} /proc/mounts > /dev/null ; then
      echo Error: There is still a mount active under ${prefix}, refusing to delete anything.
      exit 1
    else
      rm -rf ${prefix}
    fi
  '';

  adbScriptBin = name: script: pkgs.writeShellScriptBin name (
    (if pkgs ? android-tools then ''
      PATH=${pkgs.android-tools}/bin/:$PATH
    '' else ''
      command -V adb || {
        echo 'You need to build this with nixpkgs >= 21.11 or have ADB in your PATH. You can install adb via `programs.adb.enable` on NixOS'
        exit 1
      }
    '') + script);

  installCmd = adbScriptBin "installCmd" ''
    if adb shell ls -d ${prefix} ; then
      echo Error: Nix environment has been installed already. Remove it using the removeCmd.
      exit 1
    fi

    tmpdir="$(mktemp -d)"

    # Create new Nix store in tmpdir on host
    nix-env --store "$tmpdir" -i ${recoveryEnv} -p "$tmpdir"/nix/var/nix/profiles/default --extra-substituters "auto?trusted=1"

    # Copy Nix store over to the device
    adb shell mkdir -p ${prefix}
    time tar cf - -C "$tmpdir" nix/ | ${getExe pkgs.pv} | gzip -2 | adb shell 'gzip -d | tar xf - -C ${prefix}/'

    chmod -R +w "$tmpdir" && rm -r "$tmpdir"

    # Provide handy script to enter an env with Nix
    adb push ${enterScript} ${prefix}/enter
    adb push ${cleanupScript} ${prefix}/cleanup
    adb push ${removalScript} ${prefix}/remove
    adb shell chmod +x ${prefix}/enter
    adb shell chmod +x ${prefix}/cleanup
    adb shell chmod +x ${prefix}/remove
    echo 'Nix has been installed, you can now run `adb shell` and then `${prefix}/enter` to get a Nix environment'

    # Fake `/etc/passwd` to make SSH work
    adb shell 'mkdir -p ${prefix}/etc/'
    adb shell 'echo "root:x:0:0::/:" > ${prefix}/etc/passwd'
  '';

  removeCmd = adbScriptBin "removeCmd" ''
    adb shell sh ${prefix}/remove

    echo "All traces of Nix removed."
  '';

  # One step because you only need to run this once and it works from there on
  runSshd = pkgs.writeShellScriptBin "runSshd" ''
    echo 'Forwarding SSH port to host'
    adb reverse tcp:4222 tcp:4222

    echo 'Need to elevate privileges to run sshd'
    sudo echo "Received privileges!" || exit 1
    echo 'Starting new SSHD'
    sudo ${pkgs.openssh}/bin/sshd -D -f /etc/ssh/sshd_config -p 4222 &
    pid=$!

    USER="''${USER:=<hostusername>}"

    echo "You can now reach your host using \`ssh $USER@127.0.0.1 -p 4222\` from the device"
    echo 'To stop the sshd, run `sudo kill' $pid'`.'
  '';

  removeForwards = pkgs.writeShellScriptBin "removeForwards" ''
    echo 'Removing all adb port forwards'
    adb forward --remove-all
    adb reverse --remove-all
  '';

  hostCmds = pkgs.buildEnv {
    name = "hostCmds";
    paths = [
      installCmd
      removeCmd
      runSshd
      removeForwards
    ];
  };
}
