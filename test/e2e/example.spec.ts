import { Application } from 'spectron';
import * as electronPath from 'electron';
import * as path from 'path';

jest.setTimeout(10000);

describe('Main window', () => {
    let app: Application;

    beforeEach(() => {
        app = new Application({
            path: electronPath.toString(),
            args: [path.join(__dirname, '..', '..')]
        });

        return app.start();
    });

    afterEach(() => {
        if (app.isRunning()) {
            return app.stop();
        }
    });

    it('opens the window', async () => {
        const { client, browserWindow } = app;

        await client.waitUntilWindowLoaded();
        const title = await browserWindow.getTitle();

        expect(title).toBe('Webpack App');
    });

    it('increments the counter', async () => {
        const { client } = app;

        await client.waitUntilWindowLoaded();
        await client.click('#increment');

        const counterText = await client.getText('#counter-value');

        expect(counterText).toBe('Current value: 1');
    });

    it('decrements the counter', async () => {
        const { client } = app;

        await client.waitUntilWindowLoaded();
        await client.click('#decrement');

        const counterText = await client.getText('#counter-value');

        expect(counterText).toBe('Current value: -1');
    });
});
