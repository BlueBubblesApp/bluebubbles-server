export type EventData = {
    event: string;
    guid?: string;
    [key: string]: any;
};

export interface PrivateApiEventHandler {

    types: string[];

    handle(data: EventData): Promise<void>;
}