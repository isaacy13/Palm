/*
 SPDX-License-Identifier: AGPL-3.0-or-later

 Copyright (C) 2025 - 2026 emexlab

 This file is part of Nyxian.

 Nyxian is free software: you can redistribute it and/or modify
 it under the terms of the GNU Affero General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 Nyxian is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 GNU Affero General Public License for more details.

 You should have received a copy of the GNU Affero General Public License
 along with Nyxian. If not, see <https://www.gnu.org/licenses/>.
*/

#include <LiveShim/vroot.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

const char *liveshim_vroot(void)
{
    static char path[4096];
    const char *root = getenv("NXROOT");
    if(root != NULL && root[0] != '\0')
    {
        return root;
    }
    const char *home = getenv("HOME");
    if(home == NULL)
    {
        return "";
    }
    snprintf(path, sizeof(path), "%s/Documents/rootfs", home);
    return path;
}
