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
    # `self` is taken for exactly one reason: it is this flake's own source in
    # the store, and that is the only repo location a `nix run` wrapper can be
    # sure of at runtime (see rootPreamble). Nothing else here needs it.
    #
    # `...` rather than a closed { self, nixpkgs }: adding a second input later
    # would otherwise fail with "called with unexpected argument 'foo'".
    { self, nixpkgs, ... }:
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
          # The cd was never the weak part -- $REPO_ROOT was. Until the anchor in
          # rootPreamble was fixed this line could cd into whatever unrelated git
          # checkout the caller happened to be standing in and write
          # whitelist.json there. Started outside any checkout of this repo the
          # anchor is now the read-only store copy, where the first whitelist
          # write raises OSError 30 -- loud, immediate, and confined to this repo
          # rather than silently forking state into a stranger's tree.
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
          # "''${@:-$REPO_ROOT}", never a bare "$@". With no arguments ruff falls
          # back to ".", which under `nix run /path/to/repo#lint` is the CALLER's
          # directory -- the exact form CI and a cold agent use. Started in a
          # directory holding no Python, that printed "warning: No Python files
          # found under the given path(s)" plus "All checks passed!" and exited 0,
          # while the same command inside the repo exited 1 on seven findings;
          # started in a directory that did hold Python, it graded that instead.
          # A gate that passes by inspecting zero files is worse than no gate.
          #
          # --no-cache belongs to the same invariant and is not a speed knob.
          # Ruff derives its cache path from the cwd, not from the paths it was
          # handed, so even `ruff check "$REPO_ROOT"` drops a .ruff_cache into
          # whatever directory it was started from. --cache-dir "$REPO_ROOT/..."
          # is NOT the alternative: when the anchor is the read-only store copy
          # ruff dies with "Failed to initialize cache" and exit 2, and a linter
          # that cannot report findings is the false green all over again. Three
          # files lint in milliseconds; the cache buys this repo nothing.
          #
          # The src override is the last piece of cwd out of the report. isort
          # (the I rules) decides first-party vs third-party by looking for the
          # module under `src`, which defaults to ruff's cwd -- so the I001 hint
          # for bot.py ordered `from config import *` as first-party from inside
          # the repo and as third-party from anywhere else, and it drifted the
          # same way merely by running from a subdirectory. Same seven findings
          # either way, but a different suggested reordering, which is a different
          # `--fix`. Pinning src to the anchor makes the report byte-identical
          # from every cwd. This repo has no ruff config at all, so the override
          # contradicts nothing; if it ever gains a [tool.ruff] `src`, delete this
          # and let the file win.
          text = ''ruff check --no-cache --config "src=['$REPO_ROOT']" "''${@:-$REPO_ROOT}"'';
        };
        fmt = {
          description = "ruff format (rewrites files)";
          # Same anchor as lint, and this is the half that draws blood: `ruff
          # format` MUTATES. Run as `nix run /path/to/repo#fmt` from an unrelated
          # directory, the bare "$@" version reformatted the files sitting in
          # that directory -- reproduced, not theorised.
          #
          # The guard covers the one case an anchor cannot rescue: started
          # outside any checkout of this repo, $REPO_ROOT is the flake's own
          # source in the store, which is read-only by construction. That is the
          # safe answer -- nothing outside this repo can be written -- but
          # without the guard ruff emits one "Read-only file system (os error
          # 30)" per file and exits 2, which reads like a broken flake instead of
          # a misuse. Refuse once, saying why. Explicit paths are the caller's
          # business, so the guard stands down as soon as there are any.
          text = ''
            if [ "$#" -eq 0 ] && [ ! -w "$REPO_ROOT" ]; then
              echo "dev-fmt: refusing to format $REPO_ROOT -- it is the read-only store copy of this repo." >&2
              echo "dev-fmt: run it from a checkout, or pass REPO_ROOT=/path/to/checkout, or name paths explicitly." >&2
              exit 1
            fi
            ruff format --no-cache "''${@:-$REPO_ROOT}"
          '';
        };
      };

      # ======================================================================
      # PER-REPO BLOCK 5 -- the anchor sentinel
      # ======================================================================
      # One tracked file that exists in THIS repo and would not exist in a
      # sibling. rootPreamble below refuses to point a verb at a directory that
      # does not carry it, and falls back to the read-only store copy instead.
      # That test is what keeps `nix run /path/to/repo#fmt`, launched from inside
      # some other checkout, from reformatting that other checkout.
      #
      # bot.py is the entire program, so it cannot quietly vanish -- but if it is
      # ever renamed, rename it here in the same commit. The failure mode is safe
      # and loud rather than destructive: `dev-fmt` inside a real checkout starts
      # refusing with "read-only store copy" because the anchor fell through.
      #
      # Do NOT relax this to flake.nix, .git or README.md. Every repo in the
      # fleet has those, and "this is a repo" is precisely the mistake the
      # sentinel exists to stop; it has to mean "this is *that* repo".
      anchorFile = "bot.py";

      # ======================================================================
      # GENERIC MACHINERY -- byte-identical across the fleet, do not edit
      # ======================================================================
      # (rootPreamble reads `anchorFile` from BLOCK 5. That one name is the only
      # per-repo input this section takes; everything else here is fleet code.)

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

      # $REPO_ROOT is the anchor every verb acts on, and resolving it must not
      # trust the caller's cwd. `nix run` and `nix develop` both start in whatever
      # directory they were invoked from, so the previous
      #   REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
      # answered with the CALLER's repo -- or, outside a repo, with the caller's
      # bare cwd. Every verb inherited that mistake: `#lint` graded a directory
      # holding none of this repo's files and passed, `#fmt` rewrote one.
      #
      # Resolution order, first hit wins:
      #   1. an inherited $REPO_ROOT. This is how a wrapper started from inside
      #      `nix develop` keeps acting on the work tree (the shellHook ran this
      #      same preamble there), and it doubles as the documented escape hatch
      #      for `REPO_ROOT=/path/to/checkout nix run /elsewhere#fmt`.
      #   2. the git work tree the caller is standing in, which makes plain
      #      `nix run .#fmt` and `dev-fmt` from a subdirectory edit the files the
      #      developer is actually looking at.
      #   3. `self`, this flake's own source, baked into every wrapper at build
      #      time. Always the right files, never writable -- so a mutating verb
      #      that lands here can damage nothing and says so (see `fmt`).
      #
      # 1 and 2 are candidates, not answers: each has to carry ${anchorFile}
      # before it is accepted. That check is the entire safety property. Without
      # it, case 2 is the old bug and case 1 is a new one -- every repo in the
      # fleet exports REPO_ROOT, so one repo's `#fmt` would happily reformat
      # another's checkout. Anything that fails the check falls through to 3.
      #
      # Runs in a subshell so the loop variable does not leak into the
      # interactive shell that sources this via shellHook.
      rootPreamble = ''
        REPO_ROOT="$(
          for candidate in "''${REPO_ROOT:-}" "$(git rev-parse --show-toplevel 2>/dev/null)"; do
            if [ -n "$candidate" ] && [ -e "$candidate/${anchorFile}" ]; then
              printf '%s\n' "$candidate"
              exit 0
            fi
          done
          printf '%s\n' "${self}"
        )"
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

        # The regression gate for the defect this flake shipped with: a verb must
        # act on THIS repo whatever directory it was started from. The probe
        # directory below plays the caller's cwd -- an agent's $HOME, a sibling
        # checkout, /tmp -- and holds a file ruff has plenty to say about and
        # would gladly rewrite. It is deliberately not a git repo, because that is
        # the case that used to end in `pwd`.
        #
        # Note what is NOT asserted: dev-lint's exit code. It is 1 today because
        # bot.py has seven real findings, and it flips to 0 the day someone fixes
        # them -- pinning it would make good news look like a broken check. Both
        # assertions below survive that: lint must say nothing about the probe
        # file, and fmt must not change a byte of it.
        #
        # `run` shares the same anchor by construction (`cd "$REPO_ROOT"`) and is
        # not probed here: it needs a Discord token and a network, neither of
        # which exists in a build sandbox.
        anchoring =
          pkgs.runCommand "anchoring-check"
            {
              nativeBuildInputs = lib.attrValues (wrappers pkgs);
            }
            ''
              # The wrappers' last-resort anchor is this flake's own source, so
              # assert it is really in the sandbox. Otherwise ruff would fail on a
              # missing path, mention no file at all, and both greps below would
              # "pass" while proving nothing.
              test -e ${self}/${anchorFile}

              mkdir probe
              cd probe
              printf 'import os,sys\nx=1\n' > decoy.py
              cp decoy.py decoy.py.orig

              # Both verbs are expected to be unhappy in here -- lint reports the
              # repo's real findings, fmt refuses the read-only store copy -- so
              # neither exit code is the signal. What they touched is.
              dev-lint > lint.log 2>&1 || true
              if grep -q decoy.py lint.log; then
                echo "dev-lint inspected the caller's cwd instead of the repo:" >&2
                cat lint.log >&2
                exit 1
              fi

              dev-fmt > fmt.log 2>&1 || true
              if ! cmp -s decoy.py decoy.py.orig; then
                echo "dev-fmt rewrote a file outside the repo:" >&2
                cat fmt.log >&2
                exit 1
              fi

              touch "$out"
            '';
      });

      # `nix fmt` -- formats the *Nix* in this repo; project code is `dev-fmt`.
      # nixfmt-tree (the treefmt wrapper) rather than bare nixfmt, because bare
      # nixfmt tries to parse every path handed to it and fails on non-Nix files.
      # This file ships already formatted, so `nix fmt` is a no-op rather than a
      # diff across the fleet.
      #
      # This is the one verb here NOT anchored to $REPO_ROOT, and it cannot be:
      # `nix fmt` is nix's own verb, and nix -- not this flake -- decides which
      # paths the formatter receives, passing the cwd when the user names none.
      # A wrapper that overrode them would break `nix fmt path/to/one/file.nix`,
      # and it cannot tell that "." apart from the default. So `nix fmt` formats
      # where you stand, by design; `dev-fmt` is the anchored one, and it is what
      # touches this repo's Python.
      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
