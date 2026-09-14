# dotfiles-ansible

Provisions an Arch or Arch-based workstation (Arch, Manjaro, EndeavourOS,
CachyOS) from a fresh install to a working environment: fish in ghostty,
neovim, docker, the dotfiles from
[marcioflaviof/.dotfiles](https://github.com/marcioflaviof/.dotfiles), and
optionally the Hyprland desktop with the walker launcher.

Replaces the `run` / `dev-env` bash scripts in that repo. The difference that
matters: **configuration is symlinked, not copied**, so edits made in
`~/.config` land in the git checkout instead of being overwritten on the next
run.

## Bootstrap a new machine

```bash
sudo pacman -S --needed ansible git
git clone <this repo> ~/personal/dotfiles-ansible
cd ~/personal/dotfiles-ansible
ansible-galaxy collection install -r requirements.yml
```

Then the run itself. Two things are opt-in — the Hyprland desktop and building
neovim from source — so "everything" takes both switches:

```bash
# everything: dotfiles, packages, shell, docker, toolchains,
# the Hyprland desktop with walker, and neovim built from source
ansible-playbook site.yml -e install_hyprland=true --tags all,neovim -K
```

Or a piece at a time, each run adding to the last:

```bash
ansible-playbook site.yml -K                            # dotfiles, packages, shell, docker, toolchains
ansible-playbook site.yml -e install_hyprland=true -K   # + hyprland, waybar, hyprpaper, walker, elephant
ansible-playbook site.yml --tags neovim -K              # + neovim from source, 5-10 minutes
```

`-K` prompts for the sudo password. On plain Arch the first run also builds
`yay` from source, which needs an interactive terminal. Expect the full run to
take a while: the AUR builds alone are several minutes.

`stable` is a moving tag, so the commit that was built is recorded in
`~/.local/state/dotfiles-ansible/neovim.sha` and compared against upstream on
the next run. A machine whose neovim was built by hand has no stamp, so the
first `--tags neovim` run rebuilds once to establish it; after that a re-run is
a no-op until upstream `stable` moves.

## Re-running

The playbook is idempotent. Preview everything without touching the machine:

```bash
ansible-playbook site.yml --check --diff -K
```

## Tags

| tag | what it does |
|---|---|
| `base` | system upgrade, build toolchain, bootstrap `yay` if absent |
| `dotfiles` | clone the dotfiles repo, back up conflicts, create the symlinks |
| `packages` | all packages (sub-tags: `hyprland`, `cli`, `apps`) |
| `hyprland` | the desktop, including walker and its elephant providers (needs `-e install_hyprland=true`) |
| `shell` | fish as login shell, fisher, tmux plugin manager |
| `docker` | enable the daemon, add the user to the `docker` group |
| `toolchains` (alias `mise`) | mise plus the global node/ruby/python/rust toolchains, and Claude Code |
| `claude` | Claude Code on its own |
| `neovim` | build neovim from source (**not** in the default run) |

```bash
ansible-playbook site.yml --tags dotfiles
ansible-playbook site.yml --tags packages,shell -K
```

## What gets linked

`group_vars/all.yml` holds the map. Each entry links a path in the dotfiles
checkout to a path under `$HOME`:

```
~/.config/fish     -> ~/dev/.config/fish
~/.config/nvim     -> ~/dev/.config/nvim
~/.config/hypr     -> ~/dev/.config/hypr
~/.config/waybar   -> ~/dev/.config/waybar
~/.config/ghostty  -> ~/dev/.config/ghostty
~/.config/zellij   -> ~/dev/.config/zellij
~/.local/scripts   -> ~/dev/.local/scripts
~/.tmux.conf       -> ~/dev/.tmux.conf
~/.gitconfig       -> ~/dev/.gitconfig
```

Anything already sitting at one of those paths that is not the correct symlink
is **moved to `<path>.bak-<timestamp>`**, never deleted. After the first run,
diff the backups before removing them:

```bash
ls -d ~/.config/*.bak-*
diff -r ~/.config/hypr.bak-* ~/dev/.config/hypr
```

An existing dotfiles checkout is never fetched, reset, or modified — the clone
step only runs when the directory is absent.

## Dropped

rofi (replaced by walker plus the elephant providers), kitty and wezterm
(ghostty is the only terminal now). Nothing is uninstalled or deleted for you:
if a machine already has them, the packages and any `~/.config/rofi`,
`~/.config/kitty` or `~/.wezterm.lua` simply stop being managed here.

## The Hyprland desktop

Not installed by default, so a machine that already has a desktop keeps it.
The compositor, waybar, hyprpaper and the walker launcher are installed only
when you ask for them:

```bash
ansible-playbook site.yml -e install_hyprland=true -K
```

On a machine that should always get it, put `install_hyprland: true` in
`host_vars/<hostname>.yml` rather than passing `-e` every time. Everything else
runs either way: desktop utilities, fonts, the dotfile links and the shell,
docker and toolchain roles. To leave the `~/.config/hypr` and `~/.config/waybar`
links alone as well, add `--skip-tags dotfiles`.

## Per-machine differences

Drop a `host_vars/<hostname>.yml` to override anything from
`group_vars/all.yml`, for example a shorter package list on a laptop:

```yaml
packages_apps: [thunderbird]
```

## Testing

`test/run.sh` runs the playbook against a throwaway Arch container, so nothing
touches the machine you run it from. Containers and images are removed when the
run ends, including on Ctrl-C; `--keep-image` keeps them for a fast re-run.

```bash
./test/run.sh                       # syntax check + ansible-lint, seconds
./test/run.sh --check               # dry run of the whole playbook in a container
./test/run.sh --full                # real run: installs everything, GBs, ~20 min
./test/run.sh --full --idempotence  # real run twice, second must report changed=0
./test/run.sh --keep-image          # any of the above, keeping the image for a re-run
./test/run.sh --full -- --tags base,hyprland,apps -e install_hyprland=true
```

Anything after `--` goes to `ansible-playbook`.

The `docker` role is skipped: it enables `docker.service`, and the container has
no systemd to enable it with. What each tier is worth:

| tier | catches |
|---|---|
| default | YAML that will not parse, lint rules, deprecated modules |
| `--check` | tasks that break on a machine where nothing is installed yet |
| `--full` | package names that do not resolve, AUR builds that fail, anything ordering-dependent |
| `--full --idempotence` | tasks that report a change on every run |

## Bugs carried over from the old scripts, fixed here

- `runs/tools` installed `exa`, removed from the repos years ago, which aborted
  the script every time. Now `eza`.
- `runs/walker` ran `cargoo build --release` — a typo that meant it never
  worked. Walker is now installed from the AUR.
- `runs/thunderbird` omitted `--noconfirm` and hung waiting for input.
- `runs/tools` and `runs/hyprland` installed two competing xdg portals
  (`-wlr` and `-hyprland`). Only `-hyprland` is listed now, and the base
  `xdg-desktop-portal` is left to come in as its dependency.
- `runs/hyprland` pulled `pipewire`, `wireplumber` and
  `xdg-desktop-portal-hyprland` through `yay`; all three are in the official
  repos.
- `runs/docker` ran a bare `groupadd docker` that failed on every re-run.
- `runs/tools` cloned tpm with a plain `git clone`, which failed once the
  directory existed.
- Packages the configs reference but no script installed: `bat`, `fd`,
  `direnv`, `zoxide`, `github-cli`, `lazydocker`, `zk`.

## Not covered

- `~/.config/mise/config.toml` is not tracked in the dotfiles repo, so it is
  not deployed.
- The full `pacman -Qqen` set (GNOME, kernels, Manjaro base) is deliberately
  not captured — only the deliberate development environment is.
- The dotfiles repo itself is untouched: `run`, `dev-env` and `runs/` still
  work exactly as before.
