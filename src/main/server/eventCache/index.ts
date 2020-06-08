/**
 * A VERY simple helper class for caching items
 */
export class EventCache {
    items: string[];

    constructor() {
        this.purge();
    }

    purge() {
        this.items = [];
    }

    size() {
        return this.items.length;
    }

    add(item: string) {
        if (!this.items.includes(item))
            this.items.push(item);
    }

    find(item: string) {
        return this.items.find((i) => i === item);
    }
}
