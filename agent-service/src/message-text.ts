function decodeLayoutEscapes(text: string, apply: boolean): {
  text: string;
  decoded: number;
} {
  let output = "";
  let decoded = 0;
  let inlineCode = false;
  let fencedCode = false;
  const insideWindowsPath = (index: number): boolean => {
    let start = index;
    while (start > 0 && !/\s/.test(text[start - 1] ?? "")) start -= 1;
    return /^[A-Za-z]:\\/.test(text.slice(start, index + 1));
  };
  for (let index = 0; index < text.length;) {
    if (text[index] === "`") {
      let ticks = 1;
      while (text[index + ticks] === "`") ticks += 1;
      output += "`".repeat(ticks);
      if (ticks >= 3) fencedCode = !fencedCode;
      else if (!fencedCode && ticks === 1) inlineCode = !inlineCode;
      index += ticks;
      continue;
    }
    if (text[index] === "\\") {
      let slashes = 1;
      while (text[index + slashes] === "\\") slashes += 1;
      const marker = text[index + slashes];
      if (
        marker === "n" &&
        slashes % 2 === 1 &&
        !inlineCode &&
        !fencedCode &&
        !insideWindowsPath(index)
      ) {
        decoded += 1;
        if (apply) {
          output += "\\".repeat(Math.floor(slashes / 2));
          output += "\n";
        } else {
          output += "\\".repeat(slashes);
          output += "n";
        }
        index += slashes + 1;
        continue;
      }
      output += "\\".repeat(slashes);
      index += slashes;
      continue;
    }
    output += text[index];
    index += 1;
  }
  return { text: output, decoded };
}

/**
 * Some OpenAI-compatible providers occasionally return a whole natural-language
 * answer with JSON-style newline escapes. Normalize only messages with no real
 * newline and at least two layout escapes, and never decode inside Markdown code.
 */
export function normalizeAssistantText(text: string): string {
  if (text.includes("\n")) return text;
  const probe = decodeLayoutEscapes(text, false);
  if (probe.decoded < 2) return text;
  return decodeLayoutEscapes(text, true).text;
}
