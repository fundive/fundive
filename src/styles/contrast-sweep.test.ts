import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { execSync } from 'node:child_process'
import ts from 'typescript'
import {
  MIN_TEXT_CONTRAST,
  backgroundColorFor,
  contrastRatio,
  readPalette,
  textColorFor,
  type Palette,
  type Rgb,
  type Theme,
} from './contrast'

/**
 * Sweeps every JSX element in the app for text painted on a background it
 * cannot be read against — the failure the dark retrofit in `index.css` makes
 * easy to write by accident (a pale `bg-*-50` card whose ink is
 * `text-brand-900`, which the retrofit flips to near-white).
 *
 * Scope, deliberately narrow so a failure is always a real bug:
 *  - Base-state classes only. `hover:`/`focus:`/breakpoint variants are
 *    separate states this sweep does not model.
 *  - Backgrounds resolve up the JSX tree inside one file; a component whose
 *    outermost element sets no background is assumed to sit on the page.
 *  - Where a className expression offers alternatives (a ternary), the element
 *    is only reported when *every* alternative fails.
 *
 * Both looks are swept. A shop picks one with `theme.design`, but the source
 * is shared, so a color that only goes invisible in the other look is a bug
 * waiting for the next fork rather than someone else's problem.
 */

const GRADIENT = /^bg-(?:linear|gradient|radial|conic)|^bg-\[/
const VARIANT = /^[a-z][\w-]*(?:\[[^\]]*\])?:/

interface Candidate {
  cls: string
  rgb: Rgb
}

interface Context {
  candidates: Candidate[]
  line: number
}

function sourceFiles(): string[] {
  return execSync('git ls-files "src/**/*.tsx"', { encoding: 'utf8', cwd: process.cwd() })
    .trim()
    .split('\n')
    .filter(f => f && !f.includes('.test.'))
}

/**
 * Every constant in `styles/tokens.ts`, flattened to the class string it holds
 * for `theme`.
 *
 * Without this the sweep is nearly blind here: a card is `${CARD}`, not
 * `bg-white/70`, so an element whose only surface comes from a token looks
 * like it sits on the bare page — which in the light look is navy, and turns
 * every dark-ink-on-a-card into a false alarm.
 */
function readTokens(theme: Theme): Map<string, string> {
  const src = readFileSync('src/styles/tokens.ts', 'utf8')
  const sourceFile = ts.createSourceFile('tokens.ts', src, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS)
  const values = new Map<string, string>()

  const evaluate = (node: ts.Node): string | null => {
    if (ts.isStringLiteral(node) || ts.isNoSubstitutionTemplateLiteral(node)) return node.text
    if (ts.isIdentifier(node)) return values.get(node.text) ?? null
    if (ts.isCallExpression(node) && node.expression.getText() === 'pick' && node.arguments.length === 2) {
      return evaluate(node.arguments[theme === 'light' ? 0 : 1])
    }
    if (ts.isTemplateExpression(node)) {
      let out = node.head.text
      for (const span of node.templateSpans) {
        const part = evaluate(span.expression)
        if (part === null) return null
        out += part + span.literal.text
      }
      return out
    }
    return null
  }

  for (const statement of sourceFile.statements) {
    if (!ts.isVariableStatement(statement)) continue
    for (const decl of statement.declarationList.declarations) {
      if (!ts.isIdentifier(decl.name) || !decl.initializer) continue
      const value = evaluate(decl.initializer)
      if (value !== null) values.set(decl.name.text, value)
    }
  }
  return values
}

/**
 * The classes an element paints with, plus whether part of the expression was
 * a lookup this sweep cannot follow (`EVENT_KIND_DOT[kind]`, a helper call).
 * An element whose class list we can only half-read gets no verdict — the
 * missing part is usually the very background the text is meant to sit on.
 */
function classTokens(
  initializer: ts.JsxAttributeValue, tokens: Map<string, string>, theme: Theme,
): { classes: string[]; opaque: boolean } {
  const out: string[] = []
  let opaque = false
  const push = (text: string) => out.push(...text.split(/\s+/).filter(Boolean))
  const visit = (node: ts.Node) => {
    if (ts.isStringLiteral(node) || ts.isNoSubstitutionTemplateLiteral(node)) push(node.text)
    else if (ts.isTemplateExpression(node)) {
      push(node.head.text)
      for (const span of node.templateSpans) push(span.literal.text)
    } else if (ts.isIdentifier(node)) {
      const value = tokens.get(node.text)
      if (value) push(value)
    } else if (
      ts.isCallExpression(node) && node.expression.getText() === 'pick' && node.arguments.length === 2
    ) {
      // An inline `pick(light, dark)` at a call site. Visiting both arms would
      // hand the element a set of alternatives it never has at once, and the
      // "only fails when every alternative fails" rule would swallow the bug.
      visit(node.arguments[theme === 'light' ? 0 : 1])
      return
    } else if (ts.isElementAccessExpression(node) || ts.isCallExpression(node)) {
      opaque = true
    }
    node.forEachChild(visit)
  }
  visit(initializer)
  return { classes: [...new Set(out)].filter(t => !VARIANT.test(t)), opaque }
}

/** A full-bleed child that paints over everything its parent contains. */
function coversItsParent(classes: string[]): boolean {
  return classes.includes('absolute') && classes.includes('inset-0') &&
    classes.some(c => GRADIENT.test(c) || c.startsWith('bg-'))
}

function resolve(
  tokens: string[],
  kind: 'bg' | 'text',
  backdrops: Candidate[],
  palette: Palette,
): { candidates: Candidate[]; unknown: boolean } {
  const lookup = kind === 'bg' ? backgroundColorFor : textColorFor
  const unknown = kind === 'bg' && tokens.some(t => GRADIENT.test(t))
  const seen = new Map<string, Candidate>()
  for (const token of tokens) {
    if (!token.startsWith(`${kind}-`)) continue
    for (const backdrop of backdrops) {
      const rgb = lookup(token, palette, backdrop.rgb)
      if (rgb) seen.set(`${token}|${rgb.r},${rgb.g},${rgb.b}`, { cls: token, rgb })
    }
  }
  return { candidates: [...seen.values()], unknown }
}

interface Violation {
  file: string
  line: number
  bg: string
  bgLine: number
  text: string
  ratio: number
}

function sweepFile(file: string, palette: Palette, page: Candidate, tokens: Map<string, string>, theme: Theme): Violation[] {
  const src = readFileSync(file, 'utf8')
  const sourceFile = ts.createSourceFile(file, src, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX)
  const violations: Violation[] = []

  const walk = (node: ts.Node, bg: Context | null, text: Context | null) => {
    let childBg = bg
    let childText = text

    if (ts.isJsxElement(node) || ts.isJsxSelfClosingElement(node)) {
      const opening = ts.isJsxElement(node) ? node.openingElement : node
      const attr = opening.attributes.properties.find(
        (p): p is ts.JsxAttribute => ts.isJsxAttribute(p) && p.name.getText() === 'className',
      )
      const line = sourceFile.getLineAndCharacterOfPosition(opening.getStart()) .line + 1
      const { classes, opaque } = attr?.initializer
        ? classTokens(attr.initializer, tokens, theme)
        : { classes: [] as string[], opaque: false }

      if (classes.includes('sr-only') || classes.includes('hidden')) return

      const ownBg = resolve(classes, 'bg', bg?.candidates ?? [page], palette)
      const unreadableBg = ownBg.unknown || opaque
      if (unreadableBg) childBg = null
      else if (ownBg.candidates.length) childBg = { candidates: ownBg.candidates, line }

      // A gradient/arbitrary/computed fill of its own means we do not know what
      // this element's text sits on — falling back to an ancestor's card would
      // judge the text against a surface it never touches.
      const backdrop = unreadableBg ? null : (childBg ?? bg)
      const ownText = resolve(classes, 'text', backdrop?.candidates ?? [], palette)
      if (ownText.candidates.length) childText = { candidates: ownText.candidates, line }

      // A child painted edge-to-edge over this element replaces whatever the
      // element itself declared, for everything nested below it.
      if (ts.isJsxElement(node) && node.children.some(child => {
        const el = ts.isJsxElement(child) ? child.openingElement : ts.isJsxSelfClosingElement(child) ? child : null
        if (!el) return false
        const a = el.attributes.properties.find(
          (p): p is ts.JsxAttribute => ts.isJsxAttribute(p) && p.name.getText() === 'className',
        )
        return !!a?.initializer && coversItsParent(classTokens(a.initializer, tokens, theme).classes)
      })) childBg = null

      const declaresColor = ownBg.candidates.length > 0 || ownText.candidates.length > 0
      if (declaresColor && backdrop && childText) {
        let worst: Violation | null = null
        let allFail = true
        for (const b of backdrop.candidates) {
          for (const t of childText.candidates) {
            const ratio = contrastRatio(b.rgb, t.rgb)
            if (ratio >= MIN_TEXT_CONTRAST) {
              allFail = false
            } else if (!worst || ratio < worst.ratio) {
              worst = { file, line, bg: b.cls, bgLine: backdrop.line, text: t.cls, ratio }
            }
          }
        }
        if (allFail && worst) violations.push(worst)
      }
    }

    node.forEachChild(child => walk(child, childBg, childText))
  }

  walk(sourceFile, null, null)
  return violations
}

/**
 * What the app shell fills the page with, per theme. The dark look paints it
 * on `body`; the light look paints it with a utility on the shell element, so
 * read it off the PAGE token rather than restating the color here — a fork
 * that re-tints the shell keeps the sweep honest for free.
 */
function pageFill(theme: Theme, palette: Palette): Candidate {
  const tokens = /export const PAGE\s*=\s*pick\(\s*'([^']*)'\s*,\s*'([^']*)'/
    .exec(readFileSync('src/styles/tokens.ts', 'utf8'))
  const cls = tokens?.[theme === 'light' ? 1 : 2].split(/\s+/).find(t => t.startsWith('bg-'))
  const rgb = cls ? backgroundColorFor(cls, palette, palette.page) : null
  return rgb ? { cls, rgb } : { cls: '<page>', rgb: palette.page }
}

describe.each<Theme>(['light', 'dark'])('color-on-color contrast (%s)', theme => {
  const palette = readPalette(
    readFileSync('node_modules/tailwindcss/theme.css', 'utf8'),
    readFileSync('src/index.css', 'utf8'),
    theme,
  )
  const tokens = readTokens(theme)
  const page = pageFill(theme, palette)

  it('never paints text on a background it cannot be read against', () => {
    const violations = sourceFiles().flatMap(f => sweepFile(f, palette, page, tokens, theme))
    const report = violations
      .sort((a, b) => a.ratio - b.ratio)
      .map(v => `${v.file}:${v.line} — ${v.text} on ${v.bg} (line ${v.bgLine}) = ${v.ratio.toFixed(2)}:1`)
    expect(report).toEqual([])
  })
})
