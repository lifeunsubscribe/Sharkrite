# Contributing to FlowForge

Thanks for your interest in contributing!

## Quick Start

1. Fork the repo
2. Clone your fork
3. Make changes
4. Test locally: `./install.sh` then `forge --help`
5. Submit a PR

## Development Setup
```bash
# Clone your fork
git clone https://github.com/YOUR_USERNAME/flowforge.git
cd flowforge

# Symlink for live editing (optional)
./install.sh
rm -rf ~/.forge/lib
ln -s $(pwd)/lib ~/.forge/lib
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
- Test with `forge --dry-run` before submitting

## Questions?

Open an issue or start a discussion.