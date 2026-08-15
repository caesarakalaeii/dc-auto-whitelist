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
      #
      # `text` is bash under `set -euo pipefail`, shellcheck'd at BUILD time. It
      # starts in the caller's current directory but must never ACT on it: a
      # bare trailing "$@" is a bug, because with no arguments the tool then
      # defaults to `.`. Anchor the no-argument case to $REPO_ROOT or cd there
      # first, and anything that WRITES calls need_writable_checkout before it
      # does, because $REPO_ROOT can legitimately be the read-only store
      # snapshot (see rootPreamble and guardPreamble below).
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
          # The cd was never the weak part -- $REPO_ROOT was. Until rootPreamble
          # started proving a candidate is a checkout of THIS flake, this line
          # would cd into whatever unrelated git checkout the caller happened to
          # be standing in and write whitelist.json there.
          #
          # need_writable_checkout runs first and unconditionally, unlike in
          # `fmt`: whitelist.json is written no matter what arguments are passed,
          # so a $REPO_ROOT pointing at the read-only store snapshot cannot work.
          # Left to itself the bot would run for however long it takes someone to
          # type `!whitelist` and then die with OSError 30 mid-session; refusing
          # up front says the same thing immediately.
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
            need_writable_checkout
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
          # need_writable_checkout covers the one case an anchor cannot rescue:
          # started outside any checkout of this repo, $REPO_ROOT is the flake's
          # own source in the store, which is read-only by construction. That is
          # the safe answer -- nothing outside this repo can be written -- but
          # left alone ruff emits one "Read-only file system (os error 30)" per
          # file and exits 2, which reads like a broken flake instead of a
          # misuse. Refuse once, saying why.
          #
          # `set --` rather than an inline "''${@:-...}" so the guard runs in the
          # no-argument branch only: an explicit path is the caller's own
          # instruction and is forwarded untouched.
          text = ''
            if [ "$#" -eq 0 ]; then
              need_writable_checkout
              set -- "$REPO_ROOT"
            fi
            ruff format --no-cache "$@"
          '';
        };
      };

      # ======================================================================
      # GENERIC MACHINERY -- byte-identical in all 41 repos, do not edit
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

      # Every command gets $SRC_ROOT and $REPO_ROOT. `nix run` and `nix develop`
      # both start in whatever directory they were invoked from, and no verb may
      # act on that directory -- these two are what it acts on instead.
      #
      # $SRC_ROOT is this flake's own source, snapshotted into the store when
      # the flake was evaluated. It is the one anchor that is always available:
      # `nix run /path/to/repo#lint` tells the running program nothing whatever
      # about /path/to/repo (flake refs are location-independent by design, and
      # there is no $FLAKE_DIR to read), so without `self` a wrapper invoked
      # that way has literally no way to name the repo it belongs to. Its one
      # limitation is that it is read-only, being a store path.
      #
      # $REPO_ROOT is the writable checkout when the caller is standing in one,
      # and $SRC_ROOT when they are not. `git rev-parse --show-toplevel` alone
      # is NOT enough to find that checkout: run from inside some OTHER git
      # repo it cheerfully answers with THAT repo's top level, and a verb that
      # trusts the answer formats a stranger's source tree. So a candidate has
      # to prove it is a checkout of this flake, by carrying a byte-identical
      # flake.nix. Compared with bash's own $(<file) rather than cmp or
      # sha256sum, so the check depends on no package at all.
      #
      # A single tracked filename is NOT enough proof either, and that was this
      # repo's own bug: keyed on a root bot.py, the anchor accepted five sibling
      # checkouts in this fleet that happen to ship one, and `nix run
      # /path/to/dc-auto-whitelist#lint` from inside dc-bot graded dc-bot. Only
      # the whole flake.nix distinguishes repos -- description, toolchain and
      # command map all differ -- so only the whole flake.nix is compared.
      #
      # Consequence worth knowing: edit flake.nix and the dev-* wrappers in an
      # already-open `nix develop` stop recognising the tree, because they were
      # built from the previous flake.nix. That is a stale shell telling you so
      # -- re-enter it. `nix run` re-evaluates every time and never sees this.
      rootPreamble = ''
        SRC_ROOT=${lib.escapeShellArg self}
        export SRC_ROOT
        REPO_ROOT="$SRC_ROOT"
        _toplevel="$(git rev-parse --show-toplevel 2>/dev/null || true)"
        if [ -n "$_toplevel" ] && [ -f "$_toplevel/flake.nix" ] &&
          [ "$(<"$_toplevel/flake.nix")" = "$(<"$SRC_ROOT/flake.nix")" ]; then
          REPO_ROOT="$_toplevel"
        fi
        unset _toplevel
        export REPO_ROOT
      '';

      # Wrappers only, not the shellHook -- an interactive shell has no business
      # carrying this function around. Any command text that writes files calls
      # it first, and it is the reason a mutating verb can fail loudly instead of
      # falling back to "well, the cwd then".
      guardPreamble = ''
        need_writable_checkout() {
          if [ "$REPO_ROOT" != "$SRC_ROOT" ]; then
            return 0
          fi
          echo "This command rewrites files, so it needs a writable checkout of" >&2
          echo "this repo -- and standing in $PWD there is none: no parent" >&2
          echo "directory is a checkout of this flake. The only tree in reach is" >&2
          echo "the read-only store snapshot $SRC_ROOT, and rewriting $PWD" >&2
          echo "instead is exactly the bug this guard exists to prevent." >&2
          echo "cd into the repo (or \`nix develop\` it), or pass an explicit path." >&2
          exit 1
        }
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
              ${guardPreamble}
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

        # The regression gate for the two defects this flake shipped with: a verb
        # must act on THIS repo whatever directory it was started from, and "THIS
        # repo" has to mean this repo rather than merely "some git checkout".
        #
        # Probe 1 is what the previous version of this check was missing. It is a
        # REAL git repo carrying a root bot.py -- the exact shape of the five
        # sibling checkouts in this fleet that also ship one (dc-bot,
        # dc-confessions, dc-ranked_queue, quote-bot, streamer_shield_dc). The
        # old probe was deliberately NOT a git repo, so it fell back to the store
        # copy for the wrong reason and went green while `nix run
        # /path/to/this#lint` run from inside dc-bot graded dc-bot's 61 findings.
        # A probe that cannot reach the buggy branch is not a gate.
        #
        # Probe 2 is the other half, and without it a guard that refused
        # everything would pass: a checkout whose flake.nix IS byte-identical
        # must still be adopted, or every verb in the repo is dead.
        #
        # Note what is NOT asserted: dev-lint's exit code. It is 1 today because
        # bot.py has seven real findings, and it flips to 0 the day someone fixes
        # them -- pinning it would make good news look like a broken check. The
        # assertions below survive that: what the verbs read and wrote is the
        # signal, plus dev-fmt's refusal, which does not depend on findings.
        #
        # `run` is not probed: it needs a Discord token and a network, neither of
        # which exists in a build sandbox. It reaches the work tree through the
        # same two lines probe 1 exercises (`need_writable_checkout`, then `cd
        # "$REPO_ROOT"`), so dev-fmt refusing there is dev-run refusing there.
        anchoring =
          pkgs.runCommand "anchoring-check"
            {
              nativeBuildInputs = [ pkgs.git ] ++ lib.attrValues (wrappers pkgs);
            }
            ''
              # The wrappers' last-resort anchor is this flake's own source, so
              # assert it is really in the sandbox -- and that it carries the
              # flake.nix the anchor compares against. Otherwise ruff would fail
              # on a missing path, mention no file at all, and every grep below
              # would "pass" while proving nothing.
              test -e ${self}/flake.nix
              test -e ${self}/bot.py

              # git wants somewhere to look for config, and the sandbox has no
              # $HOME. Pointing both scopes at /dev/null also keeps the outcome
              # independent of whatever the builder's git happens to inherit.
              export HOME="$PWD"
              export GIT_CONFIG_GLOBAL=/dev/null
              export GIT_CONFIG_SYSTEM=/dev/null

              # ---- probe 1: a sibling checkout must NOT be adopted ----
              # Same sentinel filename this repo's guard used to key on, plus a
              # flake.nix that differs -- which is exactly what a sibling is.
              mkdir decoy
              cd decoy
              git init -q -b main .
              printf 'import os,sys\nx=1\n' > bot.py
              printf 'import json\ny=2\n' > sibling_only.py
              printf '{\n  description = "a different repo";\n  outputs = _: { };\n}\n' > flake.nix
              cp -r . ../decoy.orig

              # Grepped for by NAME, not by directory: when the anchor wrongly
              # lands on the decoy, ruff is also standing in it and prints its
              # findings as bare relative paths, so a grep for "decoy" matches
              # nothing and the leak sails through. A filename this repo does
              # not contain is the thing that cannot be spelled both ways.
              dev-lint > lint.log 2>&1 || true
              if grep -q sibling_only lint.log; then
                echo "dev-lint graded the sibling checkout instead of this repo:" >&2
                cat lint.log >&2
                exit 1
              fi
              if ! grep -q ${self} lint.log; then
                echo "dev-lint reported on neither the sibling nor this repo:" >&2
                cat lint.log >&2
                exit 1
              fi

              # Refusal, not silence: fmt reaching the read-only store snapshot
              # must exit non-zero. A zero exit here would mean it found a tree
              # it believed was writable, and the only one in reach is the decoy.
              if dev-fmt > fmt.log 2>&1; then
                echo "dev-fmt succeeded inside a sibling checkout; it must refuse:" >&2
                cat fmt.log >&2
                exit 1
              fi

              # Not one byte rewritten and not one file added -- .ruff_cache
              # included, which is why this is a whole-tree diff and not a cmp.
              if ! diff -r --exclude=.git --exclude='*.log' . ../decoy.orig; then
                echo "the verbs modified the sibling checkout:" >&2
                exit 1
              fi

              # ---- probe 2: a real checkout of THIS repo must be adopted ----
              cd ..
              cp -r ${self} checkout
              chmod -R u+w checkout
              cd checkout
              git init -q -b main .

              # dev-fmt is the assertion. It calls need_writable_checkout, which
              # passes only when $REPO_ROOT moved off the store snapshot onto
              # this tree -- so a zero exit here is the acceptance path working,
              # and it is the case probe 1 must not be allowed to break.
              if ! dev-fmt > fmt.log 2>&1; then
                echo "dev-fmt refused a byte-identical checkout of this repo:" >&2
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
