/******************************************************************************
* Author: Alexey Melnichuk <mimir@newmail.ru>
*
* Copyright (C) 2014 Alexey Melnichuk <mimir@newmail.ru>
*
* Licensed according to the included 'LICENSE' document
*
* This file is part of lua-lluv library.
******************************************************************************/

#ifndef _LLUV_UDP_H_
#define _LLUV_UDP_H_

LLUV_INTERNAL void lluv_udp_initlib(lua_State *L, int nup);

LLUV_INTERNAL int lluv_udp_index(lua_State *L);

#endif