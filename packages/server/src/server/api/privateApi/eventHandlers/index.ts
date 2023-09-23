export type EventData = {
    event: string;
    guid?: string;
    data?: any;
    [key: string]: any;
};

export interface PrivateApiEventHandler {

    types: string[];

    handle(data: EventData): Promise<void>;
}