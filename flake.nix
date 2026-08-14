{
  # Keep this line accurate and one line long: `nix flake metadata` prints it,
  # and it is the first thing a cold agent learns about the repo.
  description = "dc-auto-whitelist -- Discord bot that whitelists Minecraft players over RCON. Run `nix flake show` for the command map.";

  # nixpkgs is the only input, on purpose.
  #
  # flake-utils would buy exactly one thing here -- eachDefaultSystem -- which is
  # the three-line genAttrs below. In exchange it costs a second lock node in
  # every repo (flake-utils transitively pulls `systems`, so really two), a
  # second upstream that can break one repo and not the others, and a hardcoded
  # system list this repo cannot edit. That list is currently broken: it still
  # contains x86_64-darwin, which now throws (see `systems` below).
  #
  # nixos-unstable is the same channel the author's own NixOS config tracks, so
  # `nix develop` here and `nixos-rebuild` there resolve the same store paths and
  # share one cache.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    # `...` rather than a closed { self, nixpkgs }: adding a second input later
    # would otherwise fail with "called with unexpected argument 'self'".
    { nixpkgs, ... }:
    let
      lib = nixpkgs.lib;

      # x86_64-darwin is deliberately absent. nixpkgs 26.11 replaced that whole
      # attribute set with `throw "Nixpkgs 26.11 has dropped support for
      # x86_64-darwin"`. genAttrs is lazy, so plain `nix develop` on Linux would
      # not notice -- it detonates later, on `nix flake check --all-systems`.
      # Add it back only against a separate nixpkgs-26.05-darwin input.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      # Stand-in for flake-utils.lib.eachDefaultSystem. Passes `pkgs` rather than
      # a system string, because that is what every call site below wants.
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # ======================================================================
      # PER-REPO BLOCK 1 -- the toolchain
      # ======================================================================
      # Everything the commands below need. `nix flake check` realises this
      # closure, so a typo'd attr name fails at the flake gate instead of
      # surfacing as "command not found" halfway through a task.
      #
      # Explicit `pkgs.foo`, never `with pkgs; [ ... ]`: when an attr disappears
      # in a nixpkgs bump, `with` reports a bare undefined identifier with no
      # hint of which set it came from, and the name is not greppable.
      #
      # This repo has NO manifest -- no requirements.txt, no pyproject.toml, no
      # CI workflow, no Dockerfile. The dependency set below was derived from the
      # imports in bot.py (`import discord`, `from discord.ext import commands`,
      # `from rcon import Client`); `json` and the local `config` module need
      # nothing. If you add an import, add it to withPackages here.
      #
      # Both third-party deps exist in nixpkgs, so they are baked into the
      # interpreter with withPackages instead of installed by uv/pip at runtime.
      # That is why there is no `setup` verb: this shell is complete offline, and
      # there is no .venv to fall out of date. Do NOT "improve" this by adding uv
      # and a requirements.txt -- it would trade a hermetic shell for a network
      # bootstrap that buys this repo nothing.
      #
      # Pinned by MAJOR (python313), never the rolling `python3` alias: the
      # default is already 3.14 territory, and an alias that moves under you
      # silently re-resolves every dependency in the fleet on the same afternoon.
      toolchain = pkgs: [
        # ---- this repo's ecosystem ----
        (pkgs.python313.withPackages (ps: [
          ps.discordpy
          ps.rcon
        ]))
        pkgs.ruff

        # ---- present in every repo in the fleet ----
        pkgs.git
        pkgs.jq
        pkgs.gnumake
      ];

      # ======================================================================
      # PER-REPO BLOCK 2 -- libraries that get dlopened, not linked
      # ======================================================================
      # Empty on purpose, and this is a consequence of the withPackages choice
      # above, not an oversight. LD_LIBRARY_PATH exists in this template to
      # rescue manylinux wheels, whose bundled .so files are dlopened where
      # neither patchelf nor the nix linker ever sees them. There are no wheels
      # here -- every dependency comes from nixpkgs already correctly linked --
      # so the variable is left untouched rather than blindly widened.
      #
      # If a future dependency needs voice support, discord.py dlopens libopus
      # through ctypes and pkgs.libopus belongs in this list. Keep it minimal;
      # LD_LIBRARY_PATH is a blunt instrument.
      nativeLibs = pkgs: [ ];

      # ======================================================================
      # PER-REPO BLOCK 3 -- constant environment variables
      # ======================================================================
      # Only values that are constants belong here. Anything that must READ an
      # existing value (LD_LIBRARY_PATH), UNSET something (SOURCE_DATE_EPOCH) or
      # touch the work tree goes in the shellHook further down.
      #
      # This attrset is applied to BOTH surfaces -- the dev shell and every
      # `nix run` wrapper -- so a command cannot behave differently depending on
      # how it was invoked.
      envVars = pkgs: {
        # bot.py reports its state with bare print(). Python buffers stdout in
        # 8 KB blocks when it is not a tty, which is exactly the case under
        # `nix run` and in any agent harness that captures output, so without
        # this a long-running `dev-run` looks silently hung until the buffer
        # happens to flush.
        PYTHONUNBUFFERED = "1";
        # A flake's source is the git-tracked tree, so __pycache__ churn dirties
        # the eval cache and grows the source hash for nothing.
        PYTHONDONTWRITEBYTECODE = "1";
      };

      # ======================================================================
      # PER-REPO BLOCK 4 -- the command map
      # ======================================================================
      # THE single source of truth. It generates `apps` (so `nix run .#run`
      # works), the `dev-*` wrappers on PATH inside the shell, and `dev-help`.
      # Nothing is written twice, so `nix flake show` can never disagree with
      # what `dev-run` actually runs.
      #
      # `build`, `test` and `setup` are absent, and their absence is the point:
      # this repo produces no artifact, ships no test suite, and needs no
      # network bootstrap. `nix flake show` therefore reports the truth. A stub
      # that echoed "not applicable" would turn the command map into a liar --
      # do not add one; add a real verb when the repo earns it.
      commands = pkgs: {
        run = {
          # `python3` unqualified is correct HERE, and only because of the
          # withPackages choice above: the wrappers prepend the nix toolchain to
          # PATH, so it resolves to the interpreter that already carries discord
          # and rcon. In a uv/.venv repo this same line would silently pick the
          # bare store python and miss every dependency.
          #
          # This is the one command that cds. bot.py opens "whitelist.json" as a
          # bare relative path, so without the cd an agent invoking the bot from
          # a subdirectory would quietly start a second, empty whitelist.
          #
          # KNOWN GAP, and it is the repo's, not the flake's -- do not go hunting
          # in here for it. bot.py is written against the discord.py 1.x API, but
          # 1.x is long EOL and nixpkgs ships 2.6.4, so line 10
          # (`commands.Bot(command_prefix="!")`) raises
          #   TypeError: BotBase.__init__() missing 1 required keyword-only
          #   argument: 'intents'
          # and `dev-run` dies immediately. Fixing it means passing an explicit
          # discord.Intents (with message_content enabled, which 2.x requires for
          # on_message to receive text at all) -- a source change, deliberately
          # not made as a drive-by in the commit that added this flake.
          # `from rcon import Client` was checked too and is still fine on 2.4.9.
          description = "start the Discord bot (needs a real config.py; bot.py needs a discord.py 2.x fix first)";
          text = ''
            cd "$REPO_ROOT"
            python3 bot.py "$@"
          '';
        };
        lint = {
          description = "ruff check";
          text = ''ruff check "$@"'';
        };
        fmt = {
          description = "ruff format (rewrites files)";
          text = ''ruff format "$@"'';
        };
      };

      # ======================================================================
      # GENERIC MACHINERY -- byte-identical across the fleet, do not edit
      # ======================================================================

      # Prepend, never assign: a host LD_LIBRARY_PATH may be carrying something
      # the user needs, and clobbering it breaks binaries they launch from here.
      # Linux only -- on darwin the loader variable is DYLD_*, and exporting a
      # Linux-shaped value there is at best useless. Degenerates to nothing at
      # all when nativeLibs is empty, which is the case in this repo.
      ldPreamble =
        pkgs:
        lib.optionalString (pkgs.stdenv.hostPlatform.isLinux && nativeLibs pkgs != [ ]) ''
          export LD_LIBRARY_PATH="${lib.makeLibraryPath (nativeLibs pkgs)}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        '';

      # Every command gets $REPO_ROOT. `nix run` and `nix develop` both start in
      # whatever directory they were invoked from, so a bare `.venv` silently
      # forks a second environment as soon as an agent works from a subdirectory.
      # Note we do NOT cd here: commands act on the caller's cwd on purpose, and
      # a command that needs otherwise says so itself (see `run`).
      rootPreamble = ''
        REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
        export REPO_ROOT
      '';

      # One derivation per command, reused by both `apps` and the dev shell, so
      # the two can never diverge. `dev-` prefixed because a bare `test` binary
      # earlier on PATH would shadow the POSIX shell builtin and quietly break
      # every script in the repo that uses it.
      wrappers =
        pkgs:
        lib.mapAttrs (
          name: cmd:
          pkgs.writeShellApplication {
            name = "dev-${name}";
            runtimeInputs = toolchain pkgs;
            runtimeEnv = envVars pkgs;
            meta.description = cmd.description;
            text = ''
              ${rootPreamble}
              ${ldPreamble pkgs}
              ${cmd.text}
            '';
          }
        ) (commands pkgs);

      helpFor =
        pkgs:
        let
          cmds = commands pkgs;
          names = lib.attrNames cmds;
          width = lib.foldl' (a: n: lib.max a (builtins.stringLength n)) 0 names;
          pad = n: n + lib.concatStrings (lib.genList (_: " ") (width - builtins.stringLength n));
          line = n: c: "  dev-${pad n}  ${c.description}";
        in
        pkgs.writeShellApplication {
          name = "dev-help";
          meta.description = "print this repo's command map (works offline)";
          text = ''
            cat <<'EOF'
            ${lib.concatStringsSep "\n" (lib.mapAttrsToList line cmds)}
            EOF
          '';
        };
    in
    {
      # `nix flake show` -- the discovery entrypoint, and deliberately the whole
      # machine-facing contract: every app carries a meta.description, which
      # `nix flake show` prints inline and `nix flake show --json` exposes at
      # .apps.<system>.<name>.description. Pure evaluation, so an agent gets the
      # entire command map in one cheap call without reading a README.
      #
      # Do NOT invent a top-level output for this (`agentManifest`, `probeThing`
      # ...). Nix answers with `warning: unknown flake output '<name>'` on every
      # single `nix flake check`, forever.
      apps = forAllSystems (
        pkgs:
        lib.mapAttrs (name: cmd: {
          type = "app";
          program = "${(wrappers pkgs).${name}}/bin/dev-${name}";
          meta.description = cmd.description;
        }) (commands pkgs)
      );

      # `nix develop` -- the toolchain, plus a dev-<verb> for every app.
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = toolchain pkgs ++ lib.attrValues (wrappers pkgs) ++ [ (helpFor pkgs) ];

          env = envVars pkgs;

          # Some C extensions and node-gyp addons compile at -O0, where glibc's
          # _FORTIFY_SOURCE becomes a hard error instead of a warning.
          hardeningDisable = [ "fortify" ];

          shellHook = ''
            # mkShell inherits SOURCE_DATE_EPOCH=315532800 (1980-01-01) from
            # stdenv, and any wheel or zip built in here then dies with "ZIP does
            # not support timestamps before 1980".
            unset SOURCE_DATE_EPOCH

            ${rootPreamble}
            ${ldPreamble pkgs}

            # Nothing networked, nothing stateful and nothing interactive above
            # this line, and nothing below it either. No venv creation, no
            # `pip install`, no `read`, no `exec $SHELL`. Bootstrapping in the
            # hook makes a cold `nix develop -c python3 bot.py` start downloading
            # before it runs anything, on EVERY invocation -- the exact failure an
            # unattended agent cannot diagnose.

            # The banner is interactive-only, and this guard is load-bearing:
            # shellHook output lands on the STDOUT of `nix develop -c <cmd>`, so
            # an unguarded echo corrupts anything parsing it
            # (`nix develop -c cat x.json | jq` fails to parse). $- is the only
            # reliable discriminator here -- it lacks `i` for `nix develop -c`
            # and has it at an interactive prompt. Do not test $PS1 (unset in
            # both) or $IN_NIX_SHELL (set in both). >&2 is the second layer, for
            # the case where a caller runs us on a pty.
            case $- in
              *i*) echo "dc-auto-whitelist dev shell -- 'dev-help' for the command map" >&2 ;;
            esac
          '';
        };
      });

      # `nix flake check` -- honest by construction. It realises the toolchain
      # closure (so a typo'd or currently-broken attr fails here) and builds
      # every wrapper, which runs shellcheck over every command text. Add real
      # test derivations beside it. NEVER add a check that always passes: an
      # agent reads "all checks passed!" as a signal, and a fake check makes
      # `nix flake check` a liar.
      checks = forAllSystems (pkgs: {
        toolchain =
          pkgs.runCommand "toolchain-check"
            {
              nativeBuildInputs = toolchain pkgs ++ lib.attrValues (wrappers pkgs);
            }
            ''
              for verb in ${lib.escapeShellArgs (lib.attrNames (commands pkgs))}; do
                command -v "dev-$verb" > /dev/null || {
                  echo "dev-$verb is not on PATH" >&2
                  exit 1
                }
              done

              # The two imports bot.py actually needs, proven against the
              # interpreter this flake ships rather than assumed. This is what
              # makes the check worth its build time: a nixpkgs bump that renames
              # or drops either module fails here instead of at the agent's first
              # `dev-run`.
              python3 -c 'import discord, rcon' || exit 1

              touch "$out"
            '';
      });

      # `nix fmt` -- formats the *Nix* in this repo; project code is `dev-fmt`.
      # nixfmt-tree (the treefmt wrapper) rather than bare nixfmt, because bare
      # nixfmt tries to parse every path handed to it and fails on non-Nix files.
      # This file ships already formatted, so `nix fmt` is a no-op rather than a
      # diff across the fleet.
      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
