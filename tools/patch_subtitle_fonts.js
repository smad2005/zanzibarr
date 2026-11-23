#!/usr/bin/env node
// Adds the music glyphs used by SRT lyric lines to the bundled subtitle
// fonts. The bundled Noto Sans / Serif / Mono faces lack these codepoints,
// and Android's libass runs with the "none" font provider, so a missing
// glyph is never substituted from another loaded face. The glyphs must be
// part of the selected font itself.
//
// Requires opentype.js:  npm install --prefix tools
// Run from the repository root:
//     node tools/patch_subtitle_fonts.js
//
// Source glyphs come from tools/fonts/NotoSansSymbols-Regular.ttf (SIL OFL
// 1.1, see assets/fonts/OFL.txt). Extend CODEPOINTS if subtitles need more
// symbols from that font. Re-running is idempotent.

const fs = require('fs');
const path = require('path');
const opentype = require('opentype.js');

const ROOT = path.resolve(__dirname, '..');
const FONT_DIR = path.join(ROOT, 'assets', 'fonts');
const SOURCE = path.join(__dirname, 'fonts', 'NotoSansSymbols-Regular.ttf');
const TARGETS = ['subtitle.ttf', 'subtitle_serif.ttf', 'subtitle_mono.ttf'];
const CODEPOINTS = [...'♩♪♫♬♭♮♯'].map((glyph) => glyph.codePointAt(0));

function readFont(file) {
  const bytes = fs.readFileSync(file);
  return opentype.parse(
    bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength),
  );
}

function main() {
  const source = readFont(SOURCE);
  const sourceGlyphs = source.glyphs.glyphs;
  const sourceCmap = source.tables.cmap.glyphIndexMap;

  for (const filename of TARGETS) {
    const file = path.join(FONT_DIR, filename);
    const font = readFont(file);
    const names = new Set(
      Object.values(font.glyphs.glyphs).filter(Boolean).map((g) => g.name),
    );
    const mappings = {};

    for (const codepoint of CODEPOINTS) {
      if (font.tables.cmap.glyphIndexMap[codepoint]) continue;
      const sourceIndex = sourceCmap[codepoint];
      if (sourceIndex === undefined) {
        throw new Error(`source font is missing U+${codepoint.toString(16)}`);
      }
      const src = sourceGlyphs[sourceIndex];
      let name = `nss_${src.name}`;
      let suffix = 1;
      while (names.has(name)) name = `nss_${src.name}_${suffix++}`;
      names.add(name);

      const glyph = new opentype.Glyph({
        name,
        unicode: codepoint,
        advanceWidth: src.advanceWidth,
        leftSideBearing: src.leftSideBearing || 0,
        path: src.path,
      });
      const index = font.numGlyphs;
      font.glyphs.glyphs[index] = glyph;
      font.glyphs.length = index + 1;
      font.numGlyphs = index + 1;
      mappings[codepoint] = index;
    }

    for (const table of font.tables.cmap.tables || []) {
      for (const [cp, index] of Object.entries(mappings)) {
        table.glyphIndexMap[Number(cp)] = index;
      }
    }
    for (const [cp, index] of Object.entries(mappings)) {
      font.tables.cmap.glyphIndexMap[Number(cp)] = index;
    }

    for (const platform of ['macintosh', 'windows']) {
      const n = (font.names[platform] = font.names[platform] || {});
      n.fontFamily = n.fontFamily || { en: 'Noto Sans' };
      n.fontSubfamily = n.fontSubfamily || { en: 'Regular' };
      n.fullName = n.fullName || { en: 'Noto Sans Regular' };
      n.postScriptName = n.postScriptName || { en: 'NotoSans-Regular' };
    }
    delete font.tables.gsub;
    delete font.tables.gpos;
    delete font.tables.gdef;

    const bytes = Buffer.from(font.toArrayBuffer());
    fs.writeFileSync(file, bytes);
    const check = readFont(file);
    for (const codepoint of CODEPOINTS) {
      if (!check.tables.cmap.glyphIndexMap[codepoint]) {
        throw new Error(`${filename}: U+${codepoint.toString(16)} missing`);
      }
    }
    console.log(`${filename}: ${CODEPOINTS.length} music glyphs present`);
  }
}

main();
