/******************************************************************************
* Author: Alexey Melnichuk <alexeymelnichuck@gmail.com>
*
* Copyright (C) 2014 Alexey Melnichuk <alexeymelnichuck@gmail.com>
*
* Licensed according to the included 'LICENSE' document
*
* This file is part of lua-lluv library.
******************************************************************************/

#ifndef _LLUV_CHECK_H_
#define _LLUV_CHECK_H_

LLUV_INTERNAL void lluv_check_initlib(lua_State *L, int nup, int safe);

LLUV_INTERNAL int lluv_check_index(lua_State *L);

#endif
