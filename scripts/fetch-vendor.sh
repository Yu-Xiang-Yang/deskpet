#!/bin/bash
# Downloads the pinned front-end libraries into Resources/web/vendor and verifies their SHA-256 checksums.
# The Live2D Cubism Core is not downloaded here: it is distributed under the Live2D Proprietary Software
# License and must be obtained by the user (see README.md, section "Live2D").
set -euo pipefail
cd "$(dirname "$0")/.."
DEST="Resources/web/vendor"

# sha256  path-under-vendor  url
MANIFEST=$(cat <<'EOF'
403f2f2ee8145fa17f60c5c89403056efe2680e5096ec2762036486914ed19c5 pixi.min.js https://cdn.jsdelivr.net/npm/pixi.js@6.5.10/dist/browser/pixi.min.js
af1267e6d52759b245766c578d905bfa025b532d5c3cc727c370957c4409e21b cubism4.min.js https://cdn.jsdelivr.net/npm/pixi-live2d-display@0.4.0/dist/cubism4.min.js
15fabce5b65898b32b03f5ed25e9f891a729ad4c0d6d877110a7744aa847a894 marked.min.js https://cdn.jsdelivr.net/npm/marked@12.0.2/marked.min.js
c0845096a7c4a6741f362ac506c94c1c7d27dc603bcc1bf64a587f76f2dbe3a1 purify.min.js https://cdn.jsdelivr.net/npm/dompurify@3.1.6/dist/purify.min.js
e6bfe5deebd4c7ccd272055bab63bd3ab2c73b907b6e6a22d352740a81381fd4 katex/katex.min.js https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.js
717bc9ae7853b61f0f76455dddf0ecd4f527a783f42de2ac24684899c1c46258 katex/katex.min.css https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.css
7b57d427ac6270677daf8d8380ded2cc73336f9149a167b8e1fe0d6ef66604ae katex/auto-render.min.js https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/contrib/auto-render.min.js
471ef9ae90c407af440fcdc48edfeeb562106b3267bd12d99071c162fb52ed32 hljs/highlight.min.js https://cdn.jsdelivr.net/npm/@highlightjs/cdn-assets@11.10.0/highlight.min.js
3a9a5def8b9c311e5ae43abde85c63133185eed4f0d9f67fea4b00a8308cf066 hljs/github.min.css https://cdn.jsdelivr.net/npm/@highlightjs/cdn-assets@11.10.0/styles/github.min.css
9f208d022102b1d0c7aebfecd8e42ca7997d5de636649d2b31ea63093d809019 hljs/github-dark.min.css https://cdn.jsdelivr.net/npm/@highlightjs/cdn-assets@11.10.0/styles/github-dark.min.css
0cdd387c9590a1a9f9794560022dbb59654a7d86f187aa0c81495ad42d3a7308 katex/fonts/KaTeX_AMS-Regular.woff2 https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/fonts/KaTeX_AMS-Regular.woff2
de7701e42cf1f4cf0b766c03fb27977207eee2f4fd5d76fa82188406da43ea4c katex/fonts/KaTeX_Caligraphic-Bold.woff2 https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/fonts/KaTeX_Caligraphic-Bold.woff2
5d53e70ad607c2352162dec9e0923fb54ecdafaccbf604cd8dcf7d00facb989b katex/fonts/KaTeX_Caligraphic-Regular.woff2 https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/fonts/KaTeX_Caligraphic-Regular.woff2
74444efd593c005e3f4573b44524704c0af0a937fe911cca9e94068d0d140d3f katex/fonts/KaTeX_Fraktur-Bold.woff2 https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/fonts/KaTeX_Fraktur-Bold.woff2
51814d270d06ff0255dba0799994fa4d8c84d11f09951d47595f4abb1f3602dc katex/fonts/KaTeX_Fraktur-Regular.woff2 https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/fonts/KaTeX_Fraktur-Regular.woff2
0f60d1b897938ec918c8ce073092411baf9438f6739465693ff18b0f9d20b021 katex/fonts/KaTeX_Main-Bold.woff2 https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/fonts/KaTeX_Main-Bold.woff2
99cd42a3c072d918f2f44984a807cf7aa16e13545fd0875fc07c6c65f99e715b katex/fonts/KaTeX_Main-BoldItalic.woff2 https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/fonts/KaTeX_Main-BoldItalic.woff2
97479ca6cce906abc961ecac96faa5f9ca2e61b8e7670d475826bcdee9a7c267 katex/fonts/KaTeX_Main-Italic.woff2 https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/fonts/KaTeX_Main-Italic.woff2
c2342cd8b869e01752a9321dc17213fc40d4d04c79688c1d43f2cf316abd7866 katex/fonts/KaTeX_Main-Regular.woff2 https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/fonts/KaTeX_Main-Regular.woff2
dc47344dbb6cb5b655c8460d561f4df5f501b90c804ad3c6cec65fe322351ab1 katex/fonts/KaTeX_Math-BoldItalic.woff2 https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/fonts/KaTeX_Math-BoldItalic.woff2
7af58c5ec8f132a2ddde9027c6d7814decce4d3b822a11192a42a20e2e973264 katex/fonts/KaTeX_Math-Italic.woff2 https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/fonts/KaTeX_Math-Italic.woff2
e99ae51144bf1232efcc1bfe5add36262c6866b0faab24fa75740e1b98577a62 katex/fonts/KaTeX_SansSerif-Bold.woff2 https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/fonts/KaTeX_SansSerif-Bold.woff2
00b26ac825e2095056396e0553b8ac26d3f8ad158c3826e28b4c45b385c4714a katex/fonts/KaTeX_SansSerif-Italic.woff2 https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/fonts/KaTeX_SansSerif-Italic.woff2
68e8c73ef42afd3ccec58bf0fba302cce448938e7fc020a5e31f8a952eee1342 katex/fonts/KaTeX_SansSerif-Regular.woff2 https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/fonts/KaTeX_SansSerif-Regular.woff2
036d4e95149b69ff9bcc0cd55771efeb25ffa3947293e69acd78d5ac328c684b katex/fonts/KaTeX_Script-Regular.woff2 https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/fonts/KaTeX_Script-Regular.woff2
6b47c40166b6dbe21a5dfca7718413f2147fd2399be1ba605d8ad39cedf25dfe katex/fonts/KaTeX_Size1-Regular.woff2 https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/fonts/KaTeX_Size1-Regular.woff2
d04c54219f9eaec6d4d4fd42dfb28785975a4794d6b2fc71e566b9cd6db842dd katex/fonts/KaTeX_Size2-Regular.woff2 https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/fonts/KaTeX_Size2-Regular.woff2
73d591271b1604960cb10bb90fee021670af7297017e0e98480b332d11f51995 katex/fonts/KaTeX_Size3-Regular.woff2 https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/fonts/KaTeX_Size3-Regular.woff2
a4af7d414440a1c1790825cfb700cf9cf43b0f2c4b04f0ebc523011ad9853ec0 katex/fonts/KaTeX_Size4-Regular.woff2 https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/fonts/KaTeX_Size4-Regular.woff2
71d517d67827787cfabdf186914cc3358eda539e37931941f2b2fd4a21f68c0b katex/fonts/KaTeX_Typewriter-Regular.woff2 https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/fonts/KaTeX_Typewriter-Regular.woff2
EOF
)

while read -r sum path url; do
    [ -n "$sum" ] || continue
    target="$DEST/$path"
    if [ -f "$target" ] && [ "$(shasum -a 256 "$target" | cut -d' ' -f1)" = "$sum" ]; then
        continue
    fi
    mkdir -p "$(dirname "$target")"
    curl -fsSL -o "$target.part" "$url"
    actual="$(shasum -a 256 "$target.part" | cut -d' ' -f1)"
    if [ "$actual" != "$sum" ]; then
        rm -f "$target.part"
        echo "Checksum mismatch for $path (expected $sum, got $actual)" >&2
        exit 1
    fi
    mv "$target.part" "$target"
    echo "Fetched $path"
done <<< "$MANIFEST"

if [ ! -f "$DEST/live2dcubismcore.min.js" ]; then
    echo "Note: the Live2D Cubism Core is not in $DEST; install it with scripts/install-live2d.sh (see README.md)."
fi
echo "Vendor libraries are up to date."
