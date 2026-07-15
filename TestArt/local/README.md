# TestArt/local — private, gitignored test material

Everything in this directory except this README is ignored by git (see the
repo's `.gitignore`). Put licensed characters, watermarked tutorial images,
photos, or anything else you don't want redistributed via the repo here —
they'll never be committed or pushed, no matter what you `git add`.

Useful for seeing what the pipeline can actually do on real-world,
"what would this look like" material, without that material ever leaving
your machine.

`cbnc` commands don't pick this directory up automatically: pointing them
at `TestArt` scans only `TestArt`'s direct contents, not subdirectories.
Target it explicitly when you want it:

```sh
swift run cbnc tune TestArt/local -o /tmp/local-sheet
swift run cbnc import TestArt/local/whatever.png --preset just-right
```

Feel free to organize further with subdirectories of your own (e.g. a
`v2-continuous-tone/` of copyrighted photos/renders) — everything under
`TestArt/local/` is gitignored regardless of depth, since git ignoring a
directory covers its contents automatically. The same non-recursion applies
one level deeper, though: `cbnc tune TestArt/local` won't reach
`TestArt/local/some-subdir`, so target that path directly too.
