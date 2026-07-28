export const ATTACHMENT_EXTENSIONS: Record<string, string> = {
  "image/png": ".png",
  "image/jpeg": ".jpg",
  "image/webp": ".webp",
  "text/plain": ".txt",
  "text/csv": ".csv",
  "application/pdf": ".pdf",
  "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": ".xlsx",
  "application/zip": ".zip",
};

function zipEntryNames(bytes: Buffer): string[] | undefined {
  const minimumEocd = 22;
  if (bytes.length < minimumEocd) return undefined;
  const first = Math.max(0, bytes.length - 65_557);
  let eocd = -1;
  for (let offset = bytes.length - minimumEocd; offset >= first; offset -= 1) {
    if (bytes.readUInt32LE(offset) === 0x06054b50) {
      eocd = offset;
      break;
    }
  }
  if (eocd < 0 || eocd + minimumEocd > bytes.length) return undefined;
  const entries = bytes.readUInt16LE(eocd + 10);
  const commentLength = bytes.readUInt16LE(eocd + 20);
  const centralSize = bytes.readUInt32LE(eocd + 12);
  const centralOffset = bytes.readUInt32LE(eocd + 16);
  if (
    entries === 0xffff || entries > 10_000 ||
    centralSize === 0xffffffff || centralOffset === 0xffffffff ||
    eocd + minimumEocd + commentLength !== bytes.length
  ) {
    return undefined;
  }
  if (centralOffset + centralSize > eocd) return undefined;
  const names: string[] = [];
  let totalUncompressed = 0;
  let offset = centralOffset;
  for (let index = 0; index < entries; index += 1) {
    if (offset + 46 > eocd || bytes.readUInt32LE(offset) !== 0x02014b50) {
      return undefined;
    }
    const nameLength = bytes.readUInt16LE(offset + 28);
    const extraLength = bytes.readUInt16LE(offset + 30);
    const commentLength = bytes.readUInt16LE(offset + 32);
    const uncompressedSize = bytes.readUInt32LE(offset + 24);
    const localOffset = bytes.readUInt32LE(offset + 42);
    const end = offset + 46 + nameLength + extraLength + commentLength;
    totalUncompressed += uncompressedSize;
    if (
      end > eocd || localOffset + 4 > centralOffset ||
      bytes.readUInt32LE(localOffset) !== 0x04034b50 ||
      uncompressedSize > 128 * 1024 * 1024 ||
      totalUncompressed > 256 * 1024 * 1024
    ) return undefined;
    const name = bytes.subarray(offset + 46, offset + 46 + nameLength).toString("utf8");
    const normalized = name.replaceAll("\\", "/");
    if (
      !name || name.includes("\u0000") || normalized.startsWith("/") ||
      normalized.split("/").includes("..") || /^[A-Za-z]:\//.test(normalized)
    ) return undefined;
    names.push(name);
    offset = end;
  }
  return offset === centralOffset + centralSize ? names : undefined;
}

function validUtf8Text(bytes: Buffer): boolean {
  if (bytes.includes(0)) return false;
  try {
    new TextDecoder("utf-8", { fatal: true }).decode(bytes);
    return true;
  } catch {
    return false;
  }
}

export function attachmentMatchesMime(mimeType: string, bytes: Buffer): boolean {
  if (mimeType === "image/png") {
    return bytes.length >= 24 &&
      bytes.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) &&
      bytes.subarray(12, 16).toString("ascii") === "IHDR";
  }
  if (mimeType === "image/jpeg") {
    return bytes.length >= 4 && bytes[0] === 0xff && bytes[1] === 0xd8 &&
      bytes.at(-2) === 0xff && bytes.at(-1) === 0xd9;
  }
  if (mimeType === "image/webp") {
    return bytes.length >= 12 && bytes.subarray(0, 4).toString("ascii") === "RIFF" &&
      bytes.subarray(8, 12).toString("ascii") === "WEBP";
  }
  if (mimeType === "text/plain" || mimeType === "text/csv") {
    return validUtf8Text(bytes);
  }
  if (mimeType === "application/pdf") {
    return bytes.length >= 10 && bytes.subarray(0, 5).toString("ascii") === "%PDF-" &&
      bytes.subarray(Math.max(0, bytes.length - 1_024)).includes(Buffer.from("%%EOF"));
  }
  const entries = zipEntryNames(bytes);
  if (mimeType === "application/zip") return entries !== undefined;
  if (mimeType === "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet") {
    return entries?.includes("[Content_Types].xml") === true &&
      entries.includes("xl/workbook.xml");
  }
  return false;
}

export function isImageAttachment(mimeType: string): boolean {
  return mimeType === "image/png" || mimeType === "image/jpeg" || mimeType === "image/webp";
}
