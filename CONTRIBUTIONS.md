# Contributing to Sharkrite

Thanks for your interest in contributing!

## Quick Start

1. Fork the repo
2. Clone your fork
3. Make changes
4. Test locally: `./install.sh` then `rite --help`
5. Submit a PR

## Development Setup
```bash
# Clone your fork
git clone https://github.com/YOUR_USERNAME/sharkrite.git
cd sharkrite

# Symlink for live editing (optional)
./install.sh
rm -rf ~/.rite/lib
ln -s $(pwd)/lib ~/.rite/lib
```

## What We're Looking For

- Bug fixes
- Documentation improvements
- New blocker rules
- Notification integrations (Discord, Teams, etc.)
- Test coverage

## Guidelines

- Keep bash portable (no bash 5+ features)
- Follow existing code style
- Update README if adding features
- Test with `rite --dry-run` before submitting

## Questions?

Open an issue or start a discussion.