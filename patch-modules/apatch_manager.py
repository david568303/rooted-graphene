# SPDX-License-Identifier: GPL-3.0-only
#
# my-avbroot-setup injection module that preinstalls the official APatch manager
# APK as a system app, so it is present (and, with APatch's signature-authorized
# manager mode, root-capable) on first boot instead of being hand-installed.
#
# This file is copied into a pinned clone of chenxiaolong/my-avbroot-setup by
# rooted-ota.sh and registered in lib.modules.all_modules(). The APK is passed
# with --module-apatch-manager and is verified by SHA-256 at download time
# (rooted-ota.sh), so no SSH module signature is required here.
#
# The APK is dropped under /system/app, which the device's file_contexts labels
# u:object_r:system_file:s0 automatically (ExtFs applies the label on write), so
# no custom SELinux policy is needed: the manager runs as an ordinary app and
# reaches KernelPatch through the supercall path, not through binder/SELinux.

import argparse
from collections.abc import Iterable
import logging
from pathlib import Path, PurePosixPath
import shutil
from typing import override

from lib.filesystem import CpioFs, ExtFs
from lib.modules import MissingArgs, Module, ModuleRequirements

logger = logging.getLogger(__name__)


class APatchManagerModule(Module):
    NAME: str = 'apatch-manager'
    DEST: str = 'system/app/APatchManager/APatchManager.apk'

    @classmethod
    @override
    def add_args(cls, parser: argparse.ArgumentParser):
        parser.add_argument(
            '--module-apatch-manager',
            type=Path,
            help='APatch manager APK to preinstall as a system app',
        )

    def __init__(self, args: argparse.Namespace) -> None:
        apk: Path | None = getattr(args, 'module_apatch_manager', None)
        if apk is None:
            raise MissingArgs()
        self.apk: Path = apk

    @override
    def requirements(self) -> ModuleRequirements:
        return ModuleRequirements(
            boot_images=set(),
            ext_images={'system'},
            selinux_patching=False,
        )

    @override
    def inject(
        self,
        boot_fs: dict[str, CpioFs],
        ext_fs: dict[str, ExtFs],
        sepolicies: Iterable[Path],
    ) -> None:
        logger.info(f'Injecting APatch manager: {self.apk}')

        system_fs = ext_fs['system']
        dest = PurePosixPath(self.DEST)

        system_fs.mkdir(dest.parent, mode=0o755, parents=True, exist_ok=True)
        with (
            open(self.apk, 'rb') as f_in,
            system_fs.open(dest, 'wb', mode=0o644) as f_out,
        ):
            shutil.copyfileobj(f_in, f_out)
