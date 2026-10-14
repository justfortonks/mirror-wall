using System.Windows;
using System.Windows.Controls;
using MirrorWall.Core;

namespace MirrorWall;

/// <summary>Menu items shared by the menu bar, the tiles' ⋯ and right-click menus, and the slots'
/// own windows. Built when a menu opens, so ticks always match the current settings.</summary>
internal static class Menus
{
    public static MenuItem Item(string header, Action action, bool enabled = true, bool? isChecked = null)
    {
        var item = new MenuItem { Header = header, IsEnabled = enabled };
        if (isChecked is bool ticked)
        {
            item.IsCheckable = true;
            item.IsChecked = ticked;
        }
        // After the menu has closed: a dialog opened from inside a menu is unreliable.
        item.Click += (_, _) => Application.Current.Dispatcher.BeginInvoke(action);
        return item;
    }

    public static MenuItem Submenu(string header, IEnumerable<object> items)
    {
        var menu = new MenuItem { Header = header };
        foreach (var item in items) menu.Items.Add(item);
        return menu;
    }

    /// <summary>A menu whose items are rebuilt each time it opens.</summary>
    public static MenuItem Dynamic(string header, Func<IEnumerable<object>> items)
    {
        var menu = new MenuItem { Header = header };
        menu.Items.Add(new MenuItem()); // so it shows as a submenu before its first opening
        menu.SubmenuOpened += (_, e) =>
        {
            if (e.OriginalSource != menu) return;
            menu.Items.Clear();
            foreach (var item in items()) menu.Items.Add(item);
        };
        return menu;
    }

    public static ContextMenu Context(Func<IEnumerable<object>> items)
    {
        // A menu takes its font from what it opens from, which for the ⋯ button is the icon font.
        var menu = new ContextMenu { FontFamily = SystemFonts.MessageFontFamily, FontSize = SystemFonts.MessageFontSize, FontWeight = FontWeights.Normal };
        menu.Opened += (_, _) =>
        {
            menu.Items.Clear();
            foreach (var item in items()) menu.Items.Add(item);
        };
        menu.Items.Add(new MenuItem()); // replaced as it opens
        return menu;
    }

    /// <summary>Ticked size choices plus the Custom lock, for the View menu and pop-out windows' own menu.</summary>
    public static IEnumerable<object> PopOutSizeItems(SlotStore store)
    {
        foreach (var size in Enum.GetValues<PopOutSize>())
        {
            yield return Item(size.ToString(), () => store.SetPopOutSize(size), isChecked: store.PopOutSize == size);
        }
        yield return new Separator();
        yield return Item("Lock Custom Size", () => store.SetPopOutSizeLocked(!store.PopOutSizeLocked),
            enabled: store.PopOutSize == PopOutSize.Custom, isChecked: store.PopOutSizeLocked);
    }

    /// <summary>A slot's ⋯ menu (also its right-click menu).</summary>
    public static IEnumerable<object> SlotItems(Slot slot, SlotStore store, bool isFocused, Action toggleFocus, Window owner)
    {
        yield return Item(isFocused ? "Back to All Slots" : "Show Only This Slot", toggleFocus);
        yield return store.IsPoppedOut(slot)
            ? Item("Close Own Window", () => store.CloseOwnWindow(slot))
            : Item("Open in Own Window", () => store.OpenOwnWindow(slot));
        if (SpoutFeed.IsAvailable)
        {
            yield return Item("Send to OBS (Spout)", () =>
            {
                bool on = !slot.SendsToObs;
                store.SetObsFeed(slot, on);
                if (on) ObsSpoutPlugin.CheckWhenFeedTurnedOn(owner);
            }, isChecked: slot.SendsToObs);
            yield return Item("Phone Bezel in OBS Feed", () => store.SetFramesObsFeed(slot, !slot.FramesObsFeed),
                enabled: slot.SendsToObs, isChecked: slot.FramesObsFeed);
        }
        yield return Item("Rename…", () => RenameDialog.Show(owner, slot, store));
        yield return Item("Restart", () => store.Restart(slot));
        yield return Item("Show Log", () => LogWindow.Show(owner, slot));
        yield return Item("Stats for Nerds", () => store.ShowStats = !store.ShowStats, isChecked: store.ShowStats);
        yield return Item("Phone Bezel", () => store.SetBezel(slot, !slot.ShowsBezel), isChecked: slot.ShowsBezel);
        yield return new Separator();
        yield return slot.RecordingSince == null
            ? Item("Start Recording", slot.StartRecording)
            : Item("Stop Recording", () => slot.StopRecording());
        yield return Item("Show Recordings Folder", () => Native.ShowFolder(SaveFolders.Recordings));
        yield return new Separator();
        yield return Item("Take Screenshot", slot.TakeScreenshot, enabled: slot.ShowsPicture);
        yield return Item("Show Screenshots Folder", () => Native.ShowFolder(SaveFolders.Screenshots));
        var own = slot.Config.Standby;
        yield return Submenu("Standby Picture", new object[]
        {
            Item("Same as All Slots (Settings)", () => store.SetStandby(slot, null), isChecked: own == null),
            Item("Waiting Message", () => store.SetStandby(slot, StandbyPicture.Message), isChecked: own?.Kind == StandbyKind.Message),
            Item("Blank", () => store.SetStandby(slot, StandbyPicture.Blank), isChecked: own?.Kind == StandbyKind.Blank),
            // Always offered, so a slot with an image can switch to another one.
            Item("Image…", () => store.ChooseStandbyImage(slot), isChecked: own?.Kind == StandbyKind.Image),
        });
        yield return new Separator();
        yield return Item("Remove Slot", () => store.Remove(slot));
    }
}
