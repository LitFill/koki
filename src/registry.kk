/* The short names `koki add` understands.
 *
 * `koki add nel-kk` is the ergonomic form; `koki add github:LitFill/nel-kk`
 * always works and needs no entry here. Anything in this table is a Koka
 * library that already exposes its include directory in the shape koki
 * expects.
 */

module src/registry

import src/strutil

// A dependency koki can resolve from a short name.
pub struct known
  name  : string
  ref   : string
  attr  : string
  style : string    // "kokaLibraries" for a flake that publishes one, else "packages"

pub val known-libs : list<known> = [
  Known("nel-kk", "github:LitFill/nel-kk", "nonempty", "kokaLibraries"),
  Known("html", "github:koka-community/html", "default", "packages"),
  Known("json", "github:koka-community/json", "default", "packages"),
]

// Nix interpolation. Koka's own string syntax claims `${`, so templates spell
// it `#{` and expand it on the way out; a few expressions are built by
// concatenation instead, using this constant.
pub val nix-dollar : string = "$"

// The expression a consuming flake uses to reach a dependency's include
// directory, as a line of the `kokaLibsFor` list.
//
// A flake that publishes `kokaLibraries` is read through
// `kokaLibraries.<system>.<name>`: both this project's own `lib` template and
// the libraries already in the ecosystem scope that attribute per system, and
// an unscoped read would silently pick nothing.
pub fun entry-for(input : string, style : string, attr : string) : string
  val d = nix-dollar
  if style == "kokaLibraries" then
    "self.inputs." ++ input ++ ".kokaLibraries." ++ d ++ "{pkgs.stdenv.hostPlatform.system}." ++ attr ++ ".includePath"
  else
    "\"" ++ d ++ "{self.inputs." ++ input ++ ".packages." ++ d ++ "{pkgs.stdenv.hostPlatform.system}."
      ++ attr ++ "}" ++ d ++ "/share/koka/" ++ d ++ "{pkgs.koka.version}}\""

pub fun lookup(key : string) : maybe<known>
  known-libs.find fn(k) k.name == key

// The flake input attribute for a ref: the last path segment, normalised into
// something Nix accepts as an identifier.
pub fun nix-input(ref : string) : string
  str-kebab(last(str-split-char(ref, '/')).default(ref))

// A dependency the user asked for, as (input, ref, attr, style).
//
// `--library NAME` says the dependency publishes a `kokaLibraries` entry
// called NAME, and therefore names the attribute as well — that is the whole
// point of passing it. `--attr` still wins when both are given.
pub fun resolve(want : string, attr-override : maybe<string>, lib-override : maybe<string>)
    : div (string, string, string, string)
  val style-of = fn(known-style : string) if lib-override.is-just then "kokaLibraries" else known-style
  val attr-of = fn(known-attr : string)
    attr-override.default(lib-override.default(known-attr))
  match lookup(want)
    Just(k) -> ( k.name, k.ref, attr-of(k.attr), style-of(k.style) )
    Nothing -> {
      // A bare `owner/repo` is a GitHub shorthand; anything that already
      // carries a scheme is used as written.
      val ref = if explicit-ref(want) then want else "github:" ++ want
      ( nix-input(ref), ref, attr-of("default"), style-of("packages") )
    }

// Does this already name a flake input? True for `github:o/r`, `path:../x`,
// `https://host/r` and `git+https://...`, false for a bare `o/r`.
fun explicit-ref(want : string) : div bool
  if want.contains("://") then return True
  if want.contains("git+") then return True
  match str-before(want, '/')
    Nothing -> False
    Just(first) -> first.contains(":")
