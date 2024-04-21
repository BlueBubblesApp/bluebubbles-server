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
