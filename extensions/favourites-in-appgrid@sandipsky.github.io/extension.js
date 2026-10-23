// GNOME Shell hides favourite (dock-pinned) apps from the application grid:
// AppDisplay._loadApps and FolderView._loadApps both drop any app for which
// this._appFavorites.isFavorite() is true. While either method runs, make
// that check answer "no" on that one AppFavorites object, then restore it so
// the dash and the "Pin to Dash" / "Unpin" menu items keep working.
import {Extension, InjectionManager} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as AppDisplay from 'resource:///org/gnome/shell/ui/appDisplay.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

function withoutFavouriteFilter(originalMethod) {
    return function (...args) {
        const favorites = this._appFavorites;
        if (!favorites)
            return originalMethod.call(this, ...args);

        const hadOwn = Object.prototype.hasOwnProperty.call(favorites, 'isFavorite');
        const saved = favorites.isFavorite;
        favorites.isFavorite = () => false;
        try {
            return originalMethod.call(this, ...args);
        } finally {
            if (hadOwn)
                favorites.isFavorite = saved;
            else
                delete favorites.isFavorite;
        }
    };
}

function redisplayAppGrid() {
    const appDisplay = Main.overview?._overview?.controls?.appDisplay;
    appDisplay?._redisplay?.();
}

export default class FavouritesInAppGrid extends Extension {
    enable() {
        this._injectionManager = new InjectionManager();
        this._injectionManager.overrideMethod(
            AppDisplay.AppDisplay.prototype, '_loadApps', withoutFavouriteFilter);
        this._injectionManager.overrideMethod(
            AppDisplay.FolderView.prototype, '_loadApps', withoutFavouriteFilter);
        redisplayAppGrid();
    }

    disable() {
        this._injectionManager?.clear();
        this._injectionManager = null;
        redisplayAppGrid();
    }
}
