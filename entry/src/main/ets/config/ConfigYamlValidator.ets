import { parseDocument } from 'yaml';

const MAX_CONFIG_CHARACTERS = 5 * 1024 * 1024;

export class ConfigYamlValidator {
  static validate(content: string): string[] {
    if (content.trim().length === 0) {
      return [];
    }
    if (content.length > MAX_CONFIG_CHARACTERS) {
      return ['配置内容超过 5 MiB 限制'];
    }

    try {
      const document = parseDocument(content);
      if (document.errors.length > 0) {
        return ['配置格式无效：YAML 存在语法错误'];
      }

      const rootValue = document.toJS() as Object | null;
      if (rootValue === null || typeof rootValue !== 'object' || Array.isArray(rootValue)) {
        return ['配置格式无效：YAML 根节点必须是对象'];
      }

      const root = rootValue as Record<string, Object>;
      const errors: string[] = [];
      ConfigYamlValidator.validateProxies(root['proxies'], errors);
      ConfigYamlValidator.validateProxyGroups(root['proxy-groups'], errors);
      ConfigYamlValidator.validateRules(root['rules'], errors);
      return errors;
    } catch (err) {
      return ['配置格式无效：' + ConfigYamlValidator.safeErrorText(err)];
    }
  }

  private static validateProxies(value: Object, errors: string[]): void {
    if (value === undefined) {
      return;
    }
    if (!Array.isArray(value)) {
      errors.push('配置格式无效：proxies 必须是列表');
      return;
    }

    const names: string[] = [];
    const proxies = value as Object[];
    for (let i = 0; i < proxies.length; i++) {
      const item = proxies[i];
      if (!item || typeof item !== 'object' || Array.isArray(item)) {
        errors.push('配置格式无效：proxies 第 ' + (i + 1).toString() + ' 项必须是对象');
        continue;
      }
      const proxy = item as Record<string, Object>;
      const name = ConfigYamlValidator.requiredString(proxy, 'name',
        'proxies 第 ' + (i + 1).toString(), errors);
      ConfigYamlValidator.requiredString(proxy, 'type',
        '代理节点 ' + (name.length > 0 ? name : (i + 1).toString()), errors);
      if (name.length > 0) {
        if (names.indexOf(name) >= 0) {
          errors.push('配置格式无效：代理节点名称重复：' + name);
        } else {
          names.push(name);
        }
      }
    }
  }

  private static validateProxyGroups(value: Object, errors: string[]): void {
    if (value === undefined) {
      return;
    }
    if (!Array.isArray(value)) {
      errors.push('配置格式无效：proxy-groups 必须是列表');
      return;
    }

    const names: string[] = [];
    const groups = value as Object[];
    for (let i = 0; i < groups.length; i++) {
      const item = groups[i];
      if (!item || typeof item !== 'object' || Array.isArray(item)) {
        errors.push('配置格式无效：proxy-groups 第 ' + (i + 1).toString() + ' 项必须是对象');
        continue;
      }
      const group = item as Record<string, Object>;
      const name = ConfigYamlValidator.requiredString(group, 'name',
        'proxy-groups 第 ' + (i + 1).toString(), errors);
      ConfigYamlValidator.requiredString(group, 'type',
        '代理组 ' + (name.length > 0 ? name : (i + 1).toString()), errors);
      if (name.length > 0) {
        if (names.indexOf(name) >= 0) {
          errors.push('配置格式无效：代理组名称重复：' + name);
        } else {
          names.push(name);
        }
      }
      const proxies = group['proxies'];
      if (proxies !== undefined && !ConfigYamlValidator.isStringArray(proxies)) {
        errors.push('配置格式无效：代理组 ' + (name.length > 0 ? name : (i + 1).toString()) +
          ' 的 proxies 必须是字符串列表');
      }
    }
  }

  private static validateRules(value: Object, errors: string[]): void {
    if (value === undefined) {
      return;
    }
    if (!ConfigYamlValidator.isStringArray(value)) {
      errors.push('配置格式无效：rules 必须是字符串列表');
    }
  }

  private static requiredString(record: Record<string, Object>, key: string, owner: string,
    errors: string[]): string {
    const value = record[key];
    if (typeof value !== 'string' || value.trim().length === 0) {
      errors.push('配置格式无效：' + owner + ' 缺少 ' + key);
      return '';
    }
    return value.trim();
  }

  private static isStringArray(value: Object): boolean {
    if (!Array.isArray(value)) {
      return false;
    }
    const values = value as Object[];
    for (const item of values) {
      if (typeof item !== 'string' || item.trim().length === 0) {
        return false;
      }
    }
    return true;
  }

  private static safeErrorText(err: Object): string {
    if (err instanceof Error && err.name === 'YAMLParseError') {
      return 'YAML 存在语法错误';
    }
    return '无法解析 YAML 内容';
  }
}
