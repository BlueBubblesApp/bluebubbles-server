export interface PrivateApiEventHandler {

    types: string[];

    handle(event: any): Promise<void>;
}