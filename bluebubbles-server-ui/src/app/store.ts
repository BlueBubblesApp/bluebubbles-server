import { configureStore } from '@reduxjs/toolkit';
import ConfigSlice from './slices/ConfigSlice';
import NotificationsSlice from './slices/NotificationsSlice';
import LogsSlice from './slices/LogsSlice';
import DevicesSlice from './slices/DevicesSlice';
import StatsSlice from './slices/StatsSlice';
import WebhooksSlice from './slices/WebhooksSlice';

export const store = configureStore({
    reducer: {
        config: ConfigSlice,
        notificationStore: NotificationsSlice,
        logStore: LogsSlice,
        deviceStore: DevicesSlice,
        statistics: StatsSlice,
        webhookStore: WebhooksSlice
    },
    middleware: (getDefaultMiddleware) => getDefaultMiddleware({
        serializableCheck: false
    })
});

// Infer the `RootState` and `AppDispatch` types from the store itself
export type RootState = ReturnType<typeof store.getState>
// Inferred type: {posts: PostsState, comments: CommentsState, users: UsersState}
export type AppDispatch = typeof store.dispatch