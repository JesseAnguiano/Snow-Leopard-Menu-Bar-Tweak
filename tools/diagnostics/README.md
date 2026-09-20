# Diagnostics

Developer-only probes live here so production regression tests remain deterministic and focused.

`inspect-swiftui-classes.sh` builds and runs `InspectSwiftUIClasses.m` to inspect relevant runtime classes on a test Mac. It is not part of the tweak build, installer, or release package.
