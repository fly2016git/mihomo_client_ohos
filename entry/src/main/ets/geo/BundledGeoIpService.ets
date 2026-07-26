import { resourceManager } from '@kit.LocalizationKit';
import fs from '@ohos.file.fs';
import { ConfigService } from '../config/ConfigService';

const RAW_FILE_NAME = 'geoip.metadb';
const MIN_DATABASE_BYTES = 1024 * 1024;
const METADATA_SCAN_BYTES = 128 * 1024;
const COPY_CHUNK_BYTES = 256 * 1024;

export interface BundledGeoIpResult {
  copied: boolean;
  path: string;
  bytes: number;
}

export class BundledGeoIpService {
  static ensureInstalled(filesDir: string, manager: resourceManager.ResourceManager): BundledGeoIpResult {
    const layout = new ConfigService(filesDir).ensureLayout();
    const targetPath = layout.homeDir + '/' + RAW_FILE_NAME;
    if (BundledGeoIpService.isValidDatabaseFile(targetPath)) {
      return {
        copied: false,
        path: targetPath,
        bytes: fs.statSync(targetPath).size
      };
    }

    const content = manager.getRawFileContentSync(RAW_FILE_NAME);
    if (!BundledGeoIpService.isValidDatabaseContent(content)) {
      throw new Error('Bundled geoip.metadb is invalid');
    }

    const tmpPath = targetPath + '.tmp.' + Date.now().toString() + '.' +
      Math.floor(Math.random() * 1000000).toString();
    try {
      BundledGeoIpService.writeBytes(tmpPath, content);
      if (fs.statSync(tmpPath).size !== content.byteLength ||
        !BundledGeoIpService.isValidDatabaseFile(tmpPath)) {
        throw new Error('Copied geoip.metadb failed validation');
      }
      fs.renameSync(tmpPath, targetPath);
    } catch (err) {
      BundledGeoIpService.removeIfPresent(tmpPath);
      throw new Error(String(err));
    }

    return {
      copied: true,
      path: targetPath,
      bytes: content.byteLength
    };
  }

  private static isValidDatabaseContent(content: Uint8Array): boolean {
    if (content.byteLength < MIN_DATABASE_BYTES) {
      return false;
    }
    const start = Math.max(0, content.byteLength - METADATA_SCAN_BYTES);
    return BundledGeoIpService.containsAscii(content, start, 'MaxMind.com');
  }

  private static isValidDatabaseFile(path: string): boolean {
    try {
      const size = fs.statSync(path).size;
      if (size < MIN_DATABASE_BYTES) {
        return false;
      }
      const tailLength = Math.min(size, METADATA_SCAN_BYTES);
      const buffer = new ArrayBuffer(tailLength);
      const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      try {
        const bytesRead = fs.readSync(file.fd, buffer, {
          offset: size - tailLength,
          length: tailLength
        });
        if (bytesRead <= 0) {
          return false;
        }
        return BundledGeoIpService.containsAscii(new Uint8Array(buffer, 0, bytesRead), 0, 'MaxMind.com');
      } finally {
        fs.closeSync(file);
      }
    } catch (_) {
      return false;
    }
  }

  private static containsAscii(content: Uint8Array, start: number, text: string): boolean {
    if (text.length === 0 || content.byteLength - start < text.length) {
      return false;
    }
    const end = content.byteLength - text.length;
    for (let index = start; index <= end; index += 1) {
      let matched = true;
      for (let offset = 0; offset < text.length; offset += 1) {
        if (content[index + offset] !== text.charCodeAt(offset)) {
          matched = false;
          break;
        }
      }
      if (matched) {
        return true;
      }
    }
    return false;
  }

  private static writeBytes(path: string, content: Uint8Array): void {
    const file = fs.openSync(path, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      let offset = 0;
      while (offset < content.byteLength) {
        const end = Math.min(offset + COPY_CHUNK_BYTES, content.byteLength);
        const chunk = content.slice(offset, end);
        const written = fs.writeSync(file.fd, chunk.buffer);
        if (written <= 0) {
          throw new Error('Unable to write bundled geoip.metadb');
        }
        offset += written;
      }
    } finally {
      fs.closeSync(file);
    }
  }

  private static removeIfPresent(path: string): void {
    try {
      if (fs.accessSync(path)) {
        fs.unlinkSync(path);
      }
    } catch (_) {
    }
  }
}
