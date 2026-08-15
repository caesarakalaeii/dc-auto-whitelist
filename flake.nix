{
  # Keep this line accurate and one line long: `nix flake metadata` prints it,
  # and it is the first thing a cold agent learns about the repo.
  description = "dc-auto-whitelist -- Discord bot that whitelists Minecraft players over RCON. Run `nix flake show` for the command map.";

  # nixpkgs is the only input, on purpose.
  #
  # flake-utils would buy exactly one thing here -- eachDefaultSystem, which the
  # canonical block below already provides -- and it costs two extra lock nodes
  # rather than one: `nix flake metadata github:numtide/flake-utils` shows its
  # root pulling a `systems` node (nix-systems/default). Its system list is also
  # wrong for this pin: `nix eval github:numtide/flake-utils#lib.defaultSystems`
  # answers ["aarch64-darwin" "aarch64-linux" "x86_64-darwin" "x86_64-linux"],
  # and x86_64-darwin throws on the nixpkgs locked here -- lib.version reports
  # 26.11.20260813, and builtins.tryEval on
  # legacyPackages.x86_64-darwin.hello.name comes back success = false.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    # `self` is mandatory, not decoration: it is this flake's own source in the
    # store, and the canonical block's anchor is built on it.
    #
    # `...` rather than a closed { self, nixpkgs }: adding a second input later
    # would otherwise fail with "called with unexpected argument 'foo'".
    { self, nixpkgs, ... }:
    let
      lib = nixpkgs.lib;

      # ======================================================================
      # PER-REPO BLOCK 1 -- the toolchain
      # ======================================================================
      # Everything the commands below need on PATH. `checks.toolchain` realises
      # this closure, so a typo'd attr name fails at the flake gate instead of
      # surfacing as "command not found" halfway through a task.
      #
      # Explicit `pkgs.foo`, never `with pkgs; [ ... ]`: when an attr disappears
      # in a nixpkgs bump, `with` reports a bare undefined identifier with no
      # hint of which set it came from, and the name is not greppable.
      #
      # This repo has no dependency manifest. `git ls-files` lists eight files
      # and none of them is a requirements.txt, a pyproject.toml, a Dockerfile
      # or a CI workflow, so the dependency set below was read off bot.py's
      # imports -- `import discord`, `from discord.ext import commands`,
      # `from rcon import Client`. `json` is stdlib and `config` is the local
      # module beside it. If you add an import, add it to withPackages here.
      #
      # Both third-party deps exist in the locked nixpkgs
      # (python3.13-discord.py-2.6.4 and python3.13-rcon-2.4.9), so they are
      # baked into the interpreter with withPackages instead of installed by
      # uv/pip at runtime. That is why there is no `setup` verb: nothing has to
      # be fetched before the first command runs, and there is no .venv to fall
      # out of date.
      #
      # Pinned by MAJOR, never the rolling `python3` alias: in the locked
      # nixpkgs `python3` is already 3.14.7 while `python313` is 3.13.15, and an
      # alias that moves under you silently re-resolves every dependency in the
      # fleet on the same afternoon.
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
      # Empty, and it stays empty even if this repo grows voice support.
      # LD_LIBRARY_PATH is here to rescue manylinux wheels, whose bundled .so
      # files are dlopened where neither patchelf nor the nix linker ever sees
      # them; there are no wheels here, every dependency comes from nixpkgs.
      # discord.py's ctypes loader looks like the exception and is not one:
      # nixpkgs patches discord/opus.py to call libopus_loader on an absolute
      # /nix/store/...-libopus-1.6.1/lib/libopus.so (read out of the shipped
      # module with inspect.getsource), so pkgs.libopus on LD_LIBRARY_PATH would
      # change nothing.
      nativeLibs = pkgs: [ ];

      # ======================================================================
      # PER-REPO BLOCK 3 -- constant environment variables
      # ======================================================================
      # Constants only. Anything that must READ an existing value
      # (LD_LIBRARY_PATH) or UNSET something (SOURCE_DATE_EPOCH) is handled by
      # the canonical block, not here. This attrset is applied to BOTH surfaces
      # -- the dev shell and every `nix run` wrapper -- so a command cannot
      # behave differently depending on how it was invoked.
      envVars = pkgs: {
        # bot.py reports its state with a bare print() (line 15). When stdout is
        # not a tty -- `nix run`, or any agent harness that captures output --
        # CPython block-buffers it at io.DEFAULT_BUFFER_SIZE: measured on the
        # interpreter above, 8191 bytes written left the destination file empty
        # and the 8192nd byte flushed all of it. Without this a long-running
        # `dev-run` looks silently hung until the buffer fills.
        PYTHONUNBUFFERED = "1";
        # Keeps __pycache__ out of the checkout. It would not reach the flake
        # source -- .gitignore lists __pycache__/, and the store snapshot of
        # this flake contains exactly the eight tracked files -- but stale
        # bytecode beside three scripts is noise for no benefit.
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
      # this repo produces no artifact, tracks no test file, and needs no
      # network bootstrap. A stub that echoed "not applicable" would turn the
      # command map into a liar -- add a real verb when the repo earns one.
      #
      # `text` is bash under `set -euo pipefail`, shellcheck'd at BUILD time,
      # with $SRC_ROOT, $REPO_ROOT and need_writable_checkout already in scope
      # (see the canonical block below). It starts in the caller's current
      # directory but must never ACT on it.
      commands = pkgs: {
        run = {
          # `python3` unqualified is correct HERE, and only because of the
          # withPackages choice above: the wrapper prepends this toolchain to
          # PATH, so it resolves to the interpreter that already carries discord
          # and rcon. In a uv/.venv repo the same line would silently pick the
          # bare store python and miss every dependency.
          #
          # This is the one verb that cds. bot.py opens "whitelist.json" as a
          # bare relative path (lines 36, 46, 66 and 76), so without the cd an
          # agent starting the bot from a subdirectory would quietly begin a
          # second, empty whitelist.
          #
          # need_writable_checkout runs first and unconditionally, unlike in
          # `fmt`: whitelist.json is written whatever arguments are passed, and
          # whenever the caller is not standing in a checkout $REPO_ROOT is the
          # read-only store snapshot, where that write cannot succeed.
          #
          # KNOWN GAP, and it is the repo's rather than the flake's -- do not go
          # hunting for it in here. bot.py is written against the discord.py 1.x
          # API and the locked nixpkgs ships 2.6.4, so `python3 bot.py` dies on
          # line 10 (`commands.Bot(command_prefix="!")`) with
          #   TypeError: BotBase.__init__() missing 1 required keyword-only
          #   argument: 'intents'
          # -- run, not guessed. Fixing it means passing an explicit
          # discord.Intents; note that the shipped discord.Intents.
          # message_content docstring makes it the switch for whether message
          # content reaches on_message for messages that are not DMs, not from
          # the bot itself and do not mention it, which is every message this
          # bot's "!whitelist" handler cares about. That is a source change,
          # deliberately not made as a drive-by from the flake. `from rcon
          # import Client` was checked against the shipped rcon 2.4.9 and still
          # imports.
          description = "start the Discord bot (needs real credentials in config.py; bot.py needs a discord.py 2.x fix first)";
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
          # directory -- and that is the form a cold agent reaches for. Measured
          # with the ruff this flake ships (0.16.2): started in a directory with no
          # Python it prints "warning: No Python files found under the given
          # path(s)" then "All checks passed!" and exits 0; started in a
          # directory that does hold Python it grades that Python instead; and
          # pointed at this repo it exits 1 on seven findings. A gate that passes
          # by inspecting zero files is worse than no gate.
          #
          # The corollary, measured on this wrapper: "''${@:-...}" substitutes
          # only when $@ is EMPTY, so `dev-lint --output-format concise` from a
          # subdirectory hands ruff a flag and no path and ruff falls back to "."
          # again -- while a bare `dev-lint` from the same subdirectory reports
          # the repo's seven findings. Run the verb bare, or pass a path
          # alongside the flag.
          #
          # --no-cache belongs to the same invariant and is not a speed knob.
          # Ruff derives its cache path from the process's cwd, not from the
          # paths it was handed, so even `ruff check "$REPO_ROOT"` drops a
          # .ruff_cache into whatever directory it was started from -- measured.
          # --cache-dir under the anchor is NOT the alternative: pointed inside
          # the store snapshot ruff exits 2 with "Failed to initialize cache at
          # <path>: Read-only file system (os error 30)", and a linter that
          # cannot report findings is the false green all over again. The three
          # tracked .py files lint in 10-15 ms here; the cache buys this repo
          # nothing.
          text = ''ruff check --no-cache "''${@:-$REPO_ROOT}"'';
        };
        fmt = {
          description = "ruff format (rewrites files)";
          # Same anchor as lint, and this is the half that draws blood: `ruff
          # format` MUTATES. Measured, not theorised: `ruff format` with no path
          # argument, run in a scratch directory holding one badly formatted
          # file, answered "1 file reformatted" and rewrote it. That is what a
          # bare "$@" does to a stranger's tree.
          #
          # need_writable_checkout covers the one case an anchor cannot rescue:
          # started outside any checkout of this repo, $REPO_ROOT is the flake's
          # own source in the store, which is read-only by construction. That is
          # the safe answer -- nothing outside this repo can be written -- but
          # left alone ruff prints "error: Failed to write <path>: Read-only file
          # system (os error 30)" for the files it wants to rewrite and exits 2,
          # which reads like a broken flake instead of a misuse. Refuse once,
          # saying why.
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
      # PER-REPO BLOCK 5 -- the name in the interactive dev-shell banner
      # ======================================================================
      # Cosmetic, and still has to be right: it is how a human tells two open
      # shells apart.
      repoName = "dc-auto-whitelist";

      # ======================================================================
      # PER-REPO BLOCK 6 -- checks beside the canonical toolchain/anchoring
      # ======================================================================
      extraChecks = pkgs: {
        # The two imports bot.py needs, proven against the interpreter this
        # flake ships rather than assumed. A nixpkgs bump that renames or drops
        # either module fails here instead of at an agent's first `dev-run`.
        imports = pkgs.runCommand "imports-check" { nativeBuildInputs = toolchain pkgs; } ''
          set -euo pipefail
          python3 -c 'import discord, rcon'
          touch "$out"
        '';

        # The canonical `anchoring` check proves the mechanism behaves; this one
        # proves THIS repo's verbs go through it. The decoy carries a root
        # bot.py -- the filename a marker-based anchor would have keyed on --
        # plus a flake.nix that differs and one filename this repo does not
        # contain.
        #
        # Grepped for by NAME, not by directory: if the anchor wrongly lands on
        # the decoy, ruff is also standing in it and prints bare relative paths,
        # so a grep for "decoy" matches nothing and the leak sails through.
        #
        # dev-lint's exit code is deliberately not asserted: it is 1 today
        # because bot.py has seven real findings, and it flips to 0 the day
        # somebody fixes them, which would make good news look like a broken
        # check. What the verbs read and wrote is the signal.
        #
        # `run` is not probed: it needs a Discord token and a network, neither
        # of which exists in a build sandbox. It reaches the work tree through
        # the same two lines dev-fmt does (need_writable_checkout, then
        # $REPO_ROOT), so dev-fmt refusing here is dev-run refusing here.
        verbAnchoring =
          pkgs.runCommand "verb-anchoring-check" { nativeBuildInputs = lib.attrValues (wrappers pkgs); }
            ''
              set -euo pipefail

              mkdir decoy
              cd decoy
              printf 'import os,sys\nx  =1\n' > bot.py
              printf 'import json\ny  =2\n' > sibling_only.py
              printf '{\n  description = "a different repo";\n  outputs = _: { };\n}\n' > flake.nix
              cp -r . ../decoy.orig

              dev-lint > lint.log 2>&1 || true
              if grep -q sibling_only lint.log; then
                echo "dev-lint graded the decoy instead of this repo:" >&2
                cat lint.log >&2
                exit 1
              fi
              # ...and it must have graded SOMETHING: a verb that read nothing
              # at all sails straight through the test above.
              if ! grep -q ${self} lint.log; then
                echo "dev-lint graded neither the decoy nor this repo:" >&2
                cat lint.log >&2
                exit 1
              fi

              # Refusal, not silence.
              if dev-fmt > fmt.log 2>&1; then
                echo "dev-fmt succeeded in a foreign tree; it must refuse:" >&2
                cat fmt.log >&2
                exit 1
              fi

              # Not one byte rewritten and not one file added -- a stray
              # .ruff_cache included, which is why this is a whole-tree diff.
              diff -r --exclude='*.log' . ../decoy.orig
              touch "$out"
            '';
      };

      # >>>>> BEGIN CANONICAL MACHINERY v1 <<<<<
      # ======================================================================
      # Everything from the BEGIN sentinel above to the END sentinel on the last
      # line of this file is fleet-canonical text: the same bytes in every repo
      # that carries this flake style. That is a checkable claim, not a boast --
      #
      #   sed -n '/BEGIN CANONICAL MACHINERY v1/,$p' flake.nix | sha256sum
      #
      # prints the same digest in every repo, or one of them has been edited.
      # (`,$p`, not a range ending on the END sentinel: a range whose closing
      # pattern were spelled out here would terminate on this very comment.)
      # Nothing here names a repository, a language, a tool or a project file.
      # If you find such a name below, it is contamination: the fix is to move
      # it into the per-repo section above, never to special-case it here.
      #
      # This region READS exactly these names from the per-repo section:
      #   nixpkgs  self  lib  repoName  toolchain  nativeLibs  envVars
      #   commands  extraChecks
      # and DEFINES exactly these:
      #   systems  forAllSystems  ldPreamble  rootPreamble  guardPreamble
      #   wrappers  helpFor  anchorCheck
      # plus the four flake outputs apps / devShells / checks / formatter.
      # Anything else in scope is invisible to it. The types of those eight
      # inputs, and the shell variables this region exports into command texts,
      # are specified in INTERFACE.md, which travels with this block.
      #
      # To change behaviour here you change it in every repo at once and bump
      # the version in both sentinels. A local edit is a bug by construction:
      # the digest above stops matching, and -- because rootPreamble anchors on
      # flake.nix byte-identity -- an edited working tree also stops being
      # recognised by wrappers built from the previous revision.
      # ======================================================================

      # ---- systems policy: decided once for the whole fleet ----
      #
      # Read this list as "evaluated on three, built on one". That is what was
      # measured, and it is all it means:
      #   * `nix flake check --all-systems` passes, so every output attribute
      #     below EVALUATES on all three systems.
      #   * only x86_64-linux has ever been BUILT. The machine this was verified
      #     on has no aarch64 emulation -- no binfmt handler, and `extra-
      #     platforms` is x86-only -- so aarch64 cannot be built there at all.
      # It is not a statement that anything works on aarch64. Do not upgrade it
      # into one in a README.
      #
      # Evaluating all three is still worth its seconds, because the failure it
      # catches is an eval-time failure: a `pkgs.<attr>` that exists on Linux
      # and not on darwin (`stdenv.cc.cc.lib` is the usual one) throws during
      # evaluation, and `nix flake check` without --all-systems checks only the
      # current system and sails straight past it.
      #
      # x86_64-darwin is deliberately absent. nixpkgs 26.11 replaced that whole
      # attribute set with a `throw`. genAttrs is lazy, so plain `nix develop`
      # on Linux would not notice -- it detonates later, on the --all-systems
      # run this policy requires. Add it back only against a separate
      # nixpkgs-26.05-darwin input.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      # Stand-in for flake-utils.lib.eachDefaultSystem. Passes `pkgs` rather
      # than a system string, because that is what every call site wants, and
      # keeps the system list in this file rather than in a second input's
      # hardcoded copy of it.
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # Prepend, never assign: a host LD_LIBRARY_PATH may be carrying something
      # the user needs, and clobbering it breaks binaries they launch from here.
      # Linux only -- on darwin the loader variable is DYLD_*, and exporting a
      # Linux-shaped value there is at best useless.
      #
      # `&&` short-circuits in Nix, so on darwin `nativeLibs pkgs` is never
      # forced. That is load-bearing for the systems policy above: it is what
      # lets a repo list Linux-only attrs in nativeLibs and still evaluate on
      # aarch64-darwin. Do not reorder the two operands.
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
      # that way has literally no way to name the repo it belongs to. Two
      # limitations worth knowing: it is read-only, being a store path, and in a
      # git checkout it contains only TRACKED files.
      #
      # $REPO_ROOT is the writable checkout when the caller is standing in one,
      # and $SRC_ROOT when they are not. Three things this deliberately is NOT:
      #
      #   * NOT `pwd`. A fallback to the caller's directory is how `fmt`
      #     rewrites a stranger's source tree and how `lint` prints "all checks
      #     passed" having read none of this repo.
      #   * NOT `git rev-parse --show-toplevel`. Run from inside some OTHER git
      #     repo it cheerfully answers with THAT repo's top level. It also needs
      #     git on PATH and a .git directory, so it fails on an export and in
      #     any wrapper whose toolchain omits git.
      #   * NOT an inherited $REPO_ROOT from the environment. The dev shell
      #     EXPORTS this variable, so honouring it would mean that running
      #     `nix run /path/to/B#fmt` from inside repo A's dev shell points B's
      #     formatter at A. An explicit path argument is how a caller overrides
      #     a verb's target; an ambient variable is how they do it by accident.
      #
      # Instead: walk up from $PWD and take the first ancestor that IS this
      # repo, proved by carrying a byte-identical flake.nix. A single tracked
      # filename, a marker directory, or a set of them is not proof -- sibling
      # repos in a fleet share those, and a decoy can be built to carry any list
      # of names you care to publish. The whole flake.nix is what distinguishes
      # repos, because description, toolchain and command map all differ, so the
      # whole flake.nix is what gets compared. Compared with bash's own
      # `$(<file)` rather than cmp or sha256sum, so the check depends on no
      # package at all -- pure builtins, correct even in a wrapper whose PATH
      # carries nothing but the repo's own toolchain.
      #
      # Consequence worth knowing: edit flake.nix and the dev-* wrappers in an
      # already-open `nix develop` stop recognising the tree, because they were
      # built from the previous flake.nix. That is a stale shell telling you so
      # -- re-enter it. `nix run` re-evaluates every time and never sees this.
      rootPreamble = ''
        SRC_ROOT=${lib.escapeShellArg "${self}"}
        export SRC_ROOT

        _dev_find_root() {
          local dir ref
          ref=$(<"$SRC_ROOT/flake.nix") || return 1
          dir=$(
            unset CDPATH
            cd -P -- "''${1:-.}" 2>/dev/null && pwd
          ) || return 1
          while [ -n "$dir" ]; do
            if [ -f "$dir/flake.nix" ] && [ "$(<"$dir/flake.nix")" = "$ref" ]; then
              printf '%s\n' "$dir"
              return 0
            fi
            dir=''${dir%/*}
          done
          return 1
        }

        REPO_ROOT="$(_dev_find_root "$PWD" || printf '%s\n' "$SRC_ROOT")"
        export REPO_ROOT
      '';

      # Wrappers only, not the shellHook -- an interactive shell has no business
      # carrying this function around. Any command text that writes files calls
      # it first, and it is the reason a mutating verb can fail loudly instead
      # of falling back to "well, the cwd then".
      #
      # The test is $REPO_ROOT != $SRC_ROOT, i.e. "rootPreamble found a real
      # checkout", not a permission or a store-path-prefix test. Both of those
      # answer a narrower question: a checkout may be read-only for unrelated
      # reasons, and a store path is not the only tree we must refuse to write.
      guardPreamble = ''
        need_writable_checkout() {
          if [ "$REPO_ROOT" != "$SRC_ROOT" ]; then
            return 0
          fi
          echo "''${0##*/}: this command rewrites files, so it needs a writable" >&2
          echo "checkout of this repo -- and standing in $PWD there is none: no" >&2
          echo "parent directory carries this flake's flake.nix. The only tree in" >&2
          echo "reach is the read-only store snapshot $SRC_ROOT, and rewriting" >&2
          echo "$PWD instead is exactly the bug this guard exists to prevent." >&2
          echo "cd into the repo (or \`nix develop\` it), or pass an explicit path." >&2
          exit 1
        }
      '';

      # One derivation per command, reused by both `apps` and the dev shell, so
      # the two can never diverge. `dev-` prefixed because a bare `test` binary
      # earlier on PATH would shadow the POSIX shell builtin and quietly break
      # every script in the repo that uses it.
      #
      # writeShellApplication, not writeShellScriptBin: it runs shellcheck at
      # BUILD time and sets `set -euo pipefail`, so an unquoted $@ or a silently
      # ignored failure is a `nix flake check` failure rather than a surprise in
      # front of an agent.
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

      # `dev-help` is generated from the same attrset as everything else, so it
      # cannot describe a verb that does not exist or miss one that does. No
      # runtimeInputs: printing the map must work with nothing installed.
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

      # The regression gate for rootPreamble and guardPreamble, which are the
      # two pieces of this flake that can silently damage a tree that is not
      # this repo. It tests the MECHANISM, not any verb, which is precisely what
      # makes it fleet-generic: it needs to know nothing about what this repo
      # does, only that the anchor resolves and the guard refuses.
      #
      # The decoy is a real directory carrying a real flake.nix that differs.
      # Marker-file anchors pass a decoy like this -- that is the whole point of
      # the probe -- and so does any anchor that trusts `pwd`. Probe 2 is the
      # other half, and without it a guard that refused everything would score a
      # perfect pass: a tree that IS byte-identical must still be adopted, or
      # every mutating verb in the repo is dead. Probe 3 pins the subdirectory
      # case, which is the normal one for an agent working inside a repo.
      #
      # A per-repo probe that drives the actual verbs is strictly better and
      # cannot live here -- it has to know which verb writes and which needs a
      # network. INTERFACE.md shows how to add one via `extraChecks`.
      anchorCheck =
        pkgs:
        pkgs.runCommand "anchor-check" { } ''
          set -euo pipefail

          # The two preambles under test, verbatim, in a file the probes source.
          # A quoted heredoc, so every $ below is the bash the wrappers see.
          cat > preamble.sh <<'CANONICAL_PREAMBLE_EOF'
          ${rootPreamble}
          ${guardPreamble}
          CANONICAL_PREAMBLE_EOF

          mkdir decoy
          printf '{\n  description = "a different repo";\n  outputs = _: { };\n}\n' > decoy/flake.nix
          printf 'do not touch me\n' > decoy/victim.txt
          cp -r decoy decoy.orig

          # ---- probe 1: a foreign tree must not be adopted ----
          if ! ( cd decoy && . ../preamble.sh && [ "$REPO_ROOT" = "$SRC_ROOT" ] ); then
            echo "anchor adopted a directory that is not this repo" >&2
            exit 1
          fi
          # In a subshell: need_writable_checkout ends in `exit`, which would
          # otherwise take this whole build down instead of failing a condition.
          if ( cd decoy && . ../preamble.sh && need_writable_checkout ) > guard.log 2>&1; then
            echo "need_writable_checkout accepted a tree that is not this repo" >&2
            exit 1
          fi
          if ! diff -r decoy decoy.orig; then
            echo "the probes modified the foreign tree" >&2
            exit 1
          fi

          # ---- probe 2: a byte-identical checkout must be adopted ----
          cp -r ${lib.escapeShellArg "${self}"} checkout
          chmod -R u+w checkout
          if ! ( cd checkout && . ../preamble.sh &&
                 [ "$REPO_ROOT" = "$(pwd -P)" ] && need_writable_checkout ); then
            echo "anchor refused a byte-identical checkout of this repo" >&2
            exit 1
          fi

          # ---- probe 3: from a subdirectory, still the checkout root ----
          mkdir -p checkout/probe3/deeper
          if ! ( cd checkout/probe3/deeper && . ../../../preamble.sh &&
                 [ "$REPO_ROOT" = "$(cd -P ../.. && pwd)" ] ); then
            echo "anchor did not walk up to the checkout root from a subdirectory" >&2
            exit 1
          fi

          touch "$out"
        '';
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

          # Natively-compiled extension modules are routinely built at -O0,
          # where glibc's _FORTIFY_SOURCE stops being a warning and becomes a
          # hard error.
          hardeningDisable = [ "fortify" ];

          shellHook = ''
            # mkShell inherits SOURCE_DATE_EPOCH=315532800 (1980-01-01) from
            # stdenv, and any wheel or zip built in here then dies with "ZIP does
            # not support timestamps before 1980".
            unset SOURCE_DATE_EPOCH

            # $REPO_ROOT and $SRC_ROOT are exported here as a convenience for
            # the human at the prompt. Every wrapper re-resolves them from
            # scratch and none of them reads these, on purpose: a stale value
            # exported by one repo's shell must never steer another repo's verb.
            ${rootPreamble}
            ${ldPreamble pkgs}

            # Nothing networked, nothing stateful and nothing interactive above
            # this line, and nothing below it either. No environment
            # bootstrapping, no dependency installation, no `read`, no
            # `exec $SHELL`. Bootstrapping in the hook makes a cold
            # `nix develop -c <anything>` start downloading before it runs
            # anything, on EVERY invocation -- the exact failure an unattended
            # agent cannot diagnose. That is what a `setup` verb is for.

            # The banner is interactive-only, and this guard is load-bearing:
            # shellHook output lands on the STDOUT of `nix develop -c <cmd>`, so
            # an unguarded echo corrupts anything parsing it
            # (`nix develop -c cat x.json | jq` fails to parse). $- is the only
            # reliable discriminator here -- it lacks `i` for `nix develop -c`
            # and has it at an interactive prompt. Do not test $PS1 (unset in
            # both) or $IN_NIX_SHELL (set in both). >&2 is the second layer, for
            # the case where a caller runs us on a pty.
            case $- in
              *i*) echo "${repoName} dev shell -- 'dev-help' for the command map" >&2 ;;
            esac
          '';
        };
      });

      # `nix flake check` -- honest by construction, and the only gate this
      # style has. `toolchain` realises the whole toolchain closure (so a typo'd
      # or currently-broken attr fails here, not halfway through a task) and
      # builds every wrapper, which runs shellcheck over every command text.
      # `anchoring` is the regression test described above.
      #
      # Repo-specific checks go in `extraChecks`, never here. They may not
      # shadow either canonical name: silently replacing `anchoring` with
      # something weaker is the exact failure this whole file exists to make
      # impossible, so a collision is an eval error with both names in it.
      #
      # NEVER add a check that always passes. An agent reads "all checks
      # passed!" as a signal, and a fake check makes `nix flake check` a liar.
      checks = forAllSystems (
        pkgs:
        let
          canonical = {
            toolchain =
              pkgs.runCommand "toolchain-check"
                {
                  nativeBuildInputs = toolchain pkgs ++ lib.attrValues (wrappers pkgs) ++ [ (helpFor pkgs) ];
                }
                ''
                  set -euo pipefail
                  dev-help > help.txt

                  # A while-read over a heredoc rather than `for x in <list>`,
                  # which is a bash syntax error when the list is empty -- and a
                  # repo with no verbs yet is a legitimate state.
                  while IFS= read -r verb; do
                    [ -n "$verb" ] || continue
                    command -v "dev-$verb" > /dev/null || {
                      echo "dev-$verb is not on PATH" >&2
                      exit 1
                    }
                    grep -q -- "dev-$verb" help.txt || {
                      echo "dev-$verb is missing from the dev-help map" >&2
                      exit 1
                    }
                  done <<'CANONICAL_VERBS_EOF'
                  ${lib.concatStringsSep "\n" (lib.attrNames (commands pkgs))}
                  CANONICAL_VERBS_EOF

                  touch "$out"
                '';
            anchoring = anchorCheck pkgs;
          };
          extra = extraChecks pkgs;
          clash = lib.intersectLists (lib.attrNames canonical) (lib.attrNames extra);
        in
        if clash != [ ] then
          throw "extraChecks must not redefine canonical checks: ${lib.concatStringsSep ", " clash}"
        else
          canonical // extra
      );

      # `nix fmt` -- formats the *Nix* in this repo; project code gets a `fmt`
      # verb. nixfmt-tree (the treefmt wrapper) rather than bare nixfmt, because
      # bare nixfmt tries to parse every path handed to it and fails on non-Nix
      # files. This file ships already formatted, so `nix fmt` is a no-op rather
      # than a diff across the fleet.
      #
      # This is the one verb here NOT anchored to $REPO_ROOT, and it cannot be:
      # `nix fmt` is nix's own verb, and nix -- not this flake -- decides which
      # paths the formatter receives, passing the cwd when the user names none.
      # A wrapper that overrode them would break `nix fmt path/to/one/file.nix`,
      # and it cannot tell that "." apart from the default. So `nix fmt` formats
      # where you stand, by design; the `fmt` verb is the anchored one.
      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
# >>>>> END CANONICAL MACHINERY v1 <<<<<
