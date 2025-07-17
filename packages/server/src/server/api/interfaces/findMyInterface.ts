import { Server } from "@server";
import path from "path";
import fs from "fs";
import { FileSystem } from "@server/fileSystem";
import { isMinBigSur, isMinSequoia, isMinSonoma } from "@server/env";
import { checkPrivateApiStatus, waitMs } from "@server/helpers/utils";
import { quitFindMyFriends, startFindMyFriends, showFindMyFriends, hideFindMyFriends } from "../apple/scripts";
import { FindMyDevice, FindMyItem, FindMyLocationItem } from "@server/api/lib/findmy/types";
import { transformFindMyItemToDevice } from "@server/api/lib/findmy/utils";
import plist from "plist";
import * as bplist from "bplist-parser";
import os from "os";

export class FindMyInterface {
    // 缓存密钥以避免重复读取
    private static fmipKey: Buffer | null = null;
    private static fmfKey: Buffer | null = null;

    /**
     * 解析 plist 文件（支持二进制和 XML 格式）
     */
    private static async parsePlistFile(filePath: string): Promise<any> {
        const fileData = fs.readFileSync(filePath);
        
        // 检查是否是二进制 plist（以 "bplist" 开头）
        if (fileData.toString('utf8', 0, 6) === 'bplist') {
            Server().logger.debug(`Parsing binary plist: ${filePath}`);
            const result = await bplist.parseBuffer(fileData);
            return result[0]; // bplist-parser 返回数组，通常取第一个元素
        } else {
            Server().logger.debug(`Parsing XML plist: ${filePath}`);
            return plist.parse(fileData.toString('utf8'));
        }
    }

    static async getFriends() {
        return Server().findMyCache.getAll();
    }

    static async getDevices(): Promise<Array<FindMyDevice> | null> {
        // if (isMinSequoia) {
        //     Server().logger.debug('Cannot fetch FindMy devices on macOS Sequoia or later.');
        //     return null;
        // }

        try {
            const [devices, items] = await Promise.all([
                FindMyInterface.readDataFile("Devices"),
                FindMyInterface.readDataFile("Items")
            ]);

            // Return null if neither of the files exist
            if (devices == null && items == null) return null;

            // Get any items with a group identifier
            const itemsWithGroup = items.filter(item => item.groupIdentifier);
            if (itemsWithGroup.length > 0) {
                try {
                    const itemGroups = await FindMyInterface.readItemGroups();
                    if (itemGroups) {
                        // Create a map of group IDs to group names
                        const groupMap = itemGroups.reduce((acc, group) => {
                            acc[group.identifier] = group.name;
                            return acc;
                        }, {} as Record<string, string>);

                        // Iterate over the items and add the group name
                        for (const item of items) {
                            if (item.groupIdentifier && groupMap[item.groupIdentifier]) {
                                item.groupName = groupMap[item.groupIdentifier];
                            }
                        }
                    }
                } catch (ex: any) {
                    Server().logger.debug('An error occurred while reading FindMy ItemGroups cache file.');
                    Server().logger.debug(String(ex));
                }
            }

            // Transform the items to match the same shape as devices
            const transformedItems = (items ?? []).map(transformFindMyItemToDevice);

            return [...(devices ?? []), ...transformedItems];
        } catch (ex: any) {
            Server().logger.debug('An error occurred while reading FindMy Device cache files.');
            Server().logger.debug(String(ex));
            return null;
        }
    }

    static async refreshDevices(): Promise<Array<FindMyDevice> | null> {
        // Can't use the Private API to refresh devices yet
        await this.refreshLocationsAccessibility();
        return await this.getDevices();
    }

    static async refreshFriends(openFindMyApp = true): Promise<FindMyLocationItem[]> {
        const papiEnabled = Server().repo.getConfig("enable_private_api") as boolean;
        if (papiEnabled && isMinBigSur && !isMinSonoma) {
            checkPrivateApiStatus();
            const result = await Server().privateApi.findmy.refreshFriends();
            const refreshLocations = result?.data?.locations ?? [];

            // Save the data to the cache
            // The cache will handle properly updating the data.
            Server().findMyCache.addAll(refreshLocations);
        }

        // No matter what, open the Find My app.
        // Don't await because it should update in the background.
        // Location updates get emitted as an event as they come in.
        if (openFindMyApp) {
            this.refreshLocationsAccessibility();
        }

        return Server().findMyCache.getAll();
    }

    static async refreshLocationsAccessibility() {
        await FileSystem.executeAppleScript(quitFindMyFriends());
        await waitMs(3000);

        // Make sure the Find My app is open.
        // Give it 5 seconds to open
        await FileSystem.executeAppleScript(startFindMyFriends());
        await waitMs(5000);

        // Bring the Find My app to the foreground so it refreshes the devices
        // Give it 15 seconods to refresh
        await FileSystem.executeAppleScript(showFindMyFriends());
        await waitMs(15000);

        // Re-hide the Find My App
        await FileSystem.executeAppleScript(hideFindMyFriends());
    }

    static async readItemGroups(): Promise<Array<any>> {
        const itemGroupsPath = path.join(FileSystem.findMyDir, "ItemGroups.data");
        if (!fs.existsSync(itemGroupsPath)) return [];

        return new Promise((resolve, reject) => {
            fs.readFile(itemGroupsPath, { encoding: "utf-8" }, (err, data) => {
                // Couldn't read the file
                if (err) return resolve(null);

                try {
                    const parsedData = JSON.parse(data.toString());
                    if (Array.isArray(parsedData)) {
                        return resolve(parsedData);
                    } else {
                        Server().logger.debug(data.toString());
                        reject(new Error("Failed to read FindMy ItemGroups cache file! It is not an array!"));
                    }
                } catch {
                    reject(new Error("Failed to read FindMy ItemGroups cache file! It is not in the correct format!"));
                }
            });
        });
    }

    /**
     * 加载 FMIP 组的解密密钥
     */
    private static async loadFMIPKey(): Promise<Buffer | null> {
        if (this.fmipKey) return this.fmipKey;

        try {
            const keyPath = path.join(os.homedir(), "FMIPDataManager.bplist");
            if (!fs.existsSync(keyPath)) {
                Server().logger.debug(`FMIP key file not found: ${keyPath}`);
                return null;
            }

            const plistData = await this.parsePlistFile(keyPath);
            
            const symmetricKeyData = plistData.symmetricKey;
            if (!symmetricKeyData) {
                Server().logger.debug("Missing symmetricKey in FMIP plist");
                return null;
            }

            let symmetricKeyBytes: Buffer;
            if (typeof symmetricKeyData === 'object' && symmetricKeyData.key) {
                // 嵌套格式: symmetricKey -> key -> data
                const keyDict = symmetricKeyData.key;
                if (keyDict.data) {
                    if (Buffer.isBuffer(keyDict.data)) {
                        symmetricKeyBytes = keyDict.data;
                    } else {
                        symmetricKeyBytes = Buffer.from(keyDict.data, 'base64');
                    }
                } else {
                    Server().logger.debug("Invalid symmetricKey structure in FMIP plist");
                    return null;
                }
            } else {
                // 直接格式: 直接是 base64 字符串
                symmetricKeyBytes = Buffer.from(symmetricKeyData, 'base64');
            }

            if (symmetricKeyBytes.length !== 32) {
                Server().logger.debug(`Invalid FMIP key length: ${symmetricKeyBytes.length} bytes, expected 32`);
                return null;
            }

            this.fmipKey = symmetricKeyBytes;
            Server().logger.debug("FMIP decryption key loaded successfully");
            return this.fmipKey;
        } catch (ex: any) {
            Server().logger.debug(`Failed to load FMIP key: ${String(ex)}`);
            return null;
        }
    }

    /**
     * 加载 FMF 组的解密密钥
     */
    private static async loadFMFKey(): Promise<Buffer | null> {
        if (this.fmfKey) return this.fmfKey;

        try {
            const keyPath = path.join(os.homedir(), "FMFDataManager.bplist");
            if (!fs.existsSync(keyPath)) {
                Server().logger.debug(`FMF key file not found: ${keyPath}`);
                return null;
            }

            const plistData = await this.parsePlistFile(keyPath);
            
            const symmetricKeyData = plistData.symmetricKey;
            if (!symmetricKeyData) {
                Server().logger.debug("Missing symmetricKey in FMF plist");
                return null;
            }

            let symmetricKeyBytes: Buffer;
            if (typeof symmetricKeyData === 'object' && symmetricKeyData.key) {
                // 嵌套格式: symmetricKey -> key -> data
                const keyDict = symmetricKeyData.key;
                if (keyDict.data) {
                    if (Buffer.isBuffer(keyDict.data)) {
                        symmetricKeyBytes = keyDict.data;
                    } else {
                        symmetricKeyBytes = Buffer.from(keyDict.data, 'base64');
                    }
                } else {
                    Server().logger.debug("Invalid symmetricKey structure in FMF plist");
                    return null;
                }
            } else {
                // 直接格式: 直接是 base64 字符串
                symmetricKeyBytes = Buffer.from(symmetricKeyData, 'base64');
            }

            if (symmetricKeyBytes.length !== 32) {
                Server().logger.debug(`Invalid FMF key length: ${symmetricKeyBytes.length} bytes, expected 32`);
                return null;
            }

            this.fmfKey = symmetricKeyBytes;
            Server().logger.debug("FMF decryption key loaded successfully");
            return this.fmfKey;
        } catch (ex: any) {
            Server().logger.debug(`Failed to load FMF key: ${String(ex)}`);
            return null;
        }
    }

    /**
     * 使用 ChaCha20-Poly1305 解密数据
     */
    private static async decryptChaCha20Poly1305(encryptedData: Buffer, key: Buffer): Promise<Buffer | null> {
        try {
            // 动态导入 @noble/ciphers 以避免编译时错误
            const { chacha20poly1305 } = await import('@noble/ciphers/chacha');
            
            if (encryptedData.length < 28) {
                Server().logger.debug("Encrypted data too short for ChaCha20-Poly1305");
                return null;
            }

            // ChaCha20-Poly1305 结构: 12字节nonce + 密文 + 16字节认证标签
            const nonce = encryptedData.subarray(0, 12);
            const ciphertextWithTag = encryptedData.subarray(12);

            // 创建解密器 - 转换为 Uint8Array
            const cipher = chacha20poly1305(new Uint8Array(key), new Uint8Array(nonce));

            // 解密数据 - 转换为 Uint8Array
            const decrypted = cipher.decrypt(new Uint8Array(ciphertextWithTag));
            
            return Buffer.from(decrypted);
        } catch (ex: any) {
            Server().logger.debug(`ChaCha20-Poly1305 decryption failed: ${String(ex)}`);
            return null;
        }
    }

    /**
     * 解密缓存文件
     */
    private static async decryptCacheFile(filePath: string, keyType: 'FMIP' | 'FMF'): Promise<any[] | null> {
        try {
            if (!fs.existsSync(filePath)) {
                return null;
            }

            // 读取并解析 plist 文件
            const plistData = await this.parsePlistFile(filePath);

            // 提取加密数据
            const encryptedData = plistData.encryptedData;
            if (!encryptedData) {
                Server().logger.debug(`Missing encryptedData in ${filePath}`);
                return null;
            }

            // 转换为 Buffer
            const encryptedBuffer = Buffer.isBuffer(encryptedData) 
                ? encryptedData 
                : Buffer.from(encryptedData);

            // 加载对应的密钥
            const key = keyType === 'FMIP' 
                ? await this.loadFMIPKey() 
                : await this.loadFMFKey();

            if (!key) {
                Server().logger.debug(`${keyType} decryption key not available`);
                return null;
            }

            // 解密数据
            const decrypted = await this.decryptChaCha20Poly1305(encryptedBuffer, key);
            if (!decrypted) {
                Server().logger.debug(`Failed to decrypt ${filePath}`);
                return null;
            }

            // 解析解密后的数据
            let parsedData: any;
            if (decrypted.toString().startsWith('bplist')) {
                // 如果是 bplist 格式
                const result = await bplist.parseBuffer(decrypted);
                parsedData = result[0];
            } else {
                // 尝试解析为 JSON
                try {
                    parsedData = JSON.parse(decrypted.toString());
                } catch {
                    Server().logger.debug(`Failed to parse decrypted data from ${filePath} as JSON`);
                    return null;
                }
            }

            // 返回数组数据
            if (Array.isArray(parsedData)) {
                return parsedData;
            } else {
                Server().logger.debug(`Decrypted data from ${filePath} is not an array`);
                return null;
            }
        } catch (ex: any) {
            Server().logger.debug(`Failed to decrypt cache file ${filePath}: ${String(ex)}`);
            return null;
        }
    }

    private static readDataFile<T extends "Devices" | "Items">(
        type: T
    ): Promise<Array<T extends "Devices" ? FindMyDevice : FindMyItem> | null> {
        const dataPath = path.join(FileSystem.findMyDir, `${type}.data`);
        
        return new Promise((resolve, reject) => {
            // 首先尝试解密方式读取
            this.decryptCacheFile(dataPath, 'FMIP')
                .then(decryptedData => {
                    if (decryptedData) {
                        Server().logger.debug(`Successfully decrypted ${type} data`);
                        return resolve(decryptedData);
                    }

                    // 如果解密失败，尝试传统方式读取（向后兼容）
                    fs.readFile(dataPath, { encoding: "utf-8" }, (err, data) => {
                        // Couldn't read the file
                        if (err) return resolve(null);

                        try {
                            const parsedData = JSON.parse(data.toString());
                            if (Array.isArray(parsedData)) {
                                return resolve(parsedData);
                            } else {
                                reject(new Error(`Failed to read FindMy ${type} cache file! It is not an array!`));
                            }
                        } catch {
                            reject(new Error(
                                `Failed to read FindMy ${type} cache file! It is not in the correct format!`
                            ));
                        }
                    });
                })
                .catch((ex: any) => {
                    Server().logger.debug(`Error reading ${type} data file: ${String(ex)}`);
                    return resolve(null);
                });
        });
    }
}
