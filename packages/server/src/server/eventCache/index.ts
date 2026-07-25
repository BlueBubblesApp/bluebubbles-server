import { isEmpty } from "@server/helpers/utils";

type EventCacheItem = {
    date: number;
    item: string;
};

/**
 * A VERY simple helper class for caching items
 */
export class EventCache {
    items: EventCacheItem[] = [];

    purge() {
        if (isEmpty(this.items)) return;
        console.info(`Purging ${this.size()} items from cache...`);
        this.items = [];
    }

    trim(msOld: number) {
        const now = new Date().getTime();
        this.items = this.items.filter(i => now - i.date < msOld);
    }

    size() {
        return this.items.length;
    }

    add(item: string): boolean {
        if (isEmpty(item)) return false;
        const existing = this.items.find(i => i.item === item);
        if (existing) return false;
        this.items.push({ date: new Date().getTime(), item });
        return true;
    }

    find(item: string): string | null {
        return this.items.find(i => i.item === item)?.item ?? null;
    }

    remove(item: string) {
        if (!item) return;
        this.items = this.items.filter(i => item !== i.item);
    }
}

/**
 * A keyed cache for high-volume event streams where linear lookup is too costly.
 */
export class KeyedEventCache {
    items: Map<string, number> = new Map();

    purge() {
        if (this.items.size === 0) return;
        console.info(`Purging ${this.size()} items from cache...`);
        this.items.clear();
    }

    trim(msOld: number) {
        const now = new Date().getTime();
        for (const [item, date] of this.items) {
            if (now - date >= msOld) this.items.delete(item);
        }
    }

    size() {
        return this.items.size;
    }

    add(item: string): boolean {
        if (isEmpty(item) || this.items.has(item)) return false;
        this.items.set(item, new Date().getTime());
        return true;
    }

    find(item: string): string | null {
        return this.items.has(item) ? item : null;
    }

    remove(item: string) {
        if (!item) return;
        this.items.delete(item);
    }
}
