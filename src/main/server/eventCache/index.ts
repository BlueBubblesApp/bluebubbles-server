/**
 * A VERY simple helper class for caching items
 */
export class EventCache {
    items: string[] = [];

    purge() {
        if (this.items.length === 0) return;
        console.info(`Purging ${this.size()} items from cache...`);
        this.items = [];
    }

    size() {
        return this.items.length;
    }

    add(item: string): boolean {
        if (!item || item.trim().length === 0) return false;
        if (this.items.includes(item)) return false;
        this.items.push(item);
        return true;
    }

    find(item: string): string {
        return this.items.find(i => i === item);
    }

    remove(item: string) {
        if (!item) return;
        this.items = this.items.filter(i => item !== i);
    }
}
