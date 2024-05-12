{
  config,
  lib,
  targetPkgs ? config.targetPkgs,
  crossPkgs ? config.crossPkgs,
  ...
}:

let
  this = config.backup;
in

{
  options.backup = {
    path = lib.mkOption {
      description = ''
        The path to back up on the device.
      '';
      default = "/data";
    };
    name = lib.mkOption {
      default = "{now}";
      description = ''
        The name of the snapshot. See the `borg create` documentation.
      '';
    };
    exclusions = lib.mkOption {
      type = with lib.types; listOf str; # TODO check via regex?
      default = [ ];
      apply = map (lib.removeSuffix "/"); # Normalise the paths
      description = ''
        Path patterns as described in `borg help patterns`. Each one is supplied to a `--exclude` argument.
      '';
    };
    recommendedExclusions = lib.mkEnableOption ''
      a set of default exclusions which cover states that are replaceable, ephemeral, not able to be backed up and caches.

      Currently, this also includes media files which are assumed to be backed up separately which is subject to change.
    '';
    borg = {
      args = lib.mkOption {
        type = lib.types.attrs; # TODO is there a more accurate type here?
        description = ''
          The arguments to pass to Borg as an attrset passed to `lib.cli.toGNUCommandLineShell`.
        '';
        default = { };
      };
      repo = lib.mkOption {
        type = lib.types.str;
        internal = true;
        description = ''
          The URI to the repository on the host machine. This gets set automatically, you should not have to edit this.
        '';
        default = builtins.throw "No borg repo specified, the host module should have done that!";
      };
      env = lib.mkOption {
        description = ''
          The set of environment variables passed to Borg invocations.
        '';
        type = lib.types.attrs;
        default = { };
      };
      package = lib.mkPackageOption targetPkgs "borgbackup" { };
      patterns = lib.mkOption {
        type = with lib.types; nullOr (either str path);
        description = ''
          A string of patterns or a patterns file according to Borg's patterns.lst file format.

          Note that only Borg understands these patterns. Use {option}`backup.exclusions` for generic exclusions.
        '';
        default = null;
      };
    };
    ncdu = {
      package = lib.mkPackageOption targetPkgs "ncdu" { };
      args = lib.mkOption {
        type = with lib.types; attrs;
        default = { };
      };
      env = lib.mkOption {
        description = ''
          The set of environment variables passed to ncdu invocations.
        '';
        type = lib.types.attrs;
        default = { };
      };
    };
  };

  config = {
    backup = {
      borg.args = {
        exclude = this.exclusions;
        patterns-from = this.borg.patterns;
      };
      exclusions = lib.mkIf this.recommendedExclusions (import ./exclusions.nix);
    };
    recovery.borgCmd =
      let
        inherit (this.borg)
          args
          repo
          env
          package
          ;
        exe = lib.getExe package;
        argString = lib.cli.toGNUCommandLineShell { } args;
      in
      crossPkgs.writeShellScriptBin "borgCmd" ''
        set -o allexport # Export the following env vars
        ${lib.toShellVars env}
        exec ${exe} ${argString} ${repo}::${this.name} ${this.path} "$@"
      '';
    recovery.ncduCmd =
      let
        inherit (this.ncdu) package args env;
        exe = lib.getExe package;
        argString = lib.cli.toGNUCommandLineShell { } args;
      in
      crossPkgs.writeShellScriptBin "ncduCmd" ''
        set -o allexport # Export the following env vars
        ${lib.toShellVars env}
        exec ${exe} ${argString} ${this.path} "$@"
      '';
  };
}
