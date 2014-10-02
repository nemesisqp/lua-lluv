/******************************************************************************
* Author: Alexey Melnichuk <mimir@newmail.ru>
*
* Copyright (C) 2014 Alexey Melnichuk <mimir@newmail.ru>
*
* Licensed according to the included 'LICENSE' document
*
* This file is part of lua-lluv library.
******************************************************************************/

#include "lluv.h"
#include "lluv_handle.h"
#include "lluv_udp.h"
#include "lluv_loop.h"
#include "lluv_error.h"
#include <assert.h>

LLUV_IMPLEMENT_XXX_REQ(udp_send, static)

#define LLUV_UDP_NAME LLUV_PREFIX" udp"
static const char *LLUV_UDP = LLUV_UDP_NAME;

LLUV_INTERNAL int lluv_udp_index(lua_State *L){
  return lluv__index(L, LLUV_UDP, lluv_handle_index);
}

static int lluv_udp_create(lua_State *L){
  lluv_loop_t   *loop   = lluv_opt_loop_ex(L, 1, LLUV_FLAG_OPEN);
  lluv_handle_t *handle = lluv_handle_create(L, UV_UDP, INHERITE_FLAGS(loop));
  int err = uv_udp_init(loop->handle, LLUV_H(handle, uv_udp_t));
  if(err < 0){
    lluv_handle_cleanup(L, handle);
    return lluv_fail(L, loop->flags, LLUV_ERR_UV, (uv_errno_t)err, NULL);
  }
  return 1;
}

static lluv_handle_t* lluv_check_udp(lua_State *L, int idx, lluv_flags_t flags){
  lluv_handle_t *handle = lluv_check_handle(L, idx, flags);
  luaL_argcheck (L, LLUV_H(handle, uv_handle_t)->type == UV_UDP, idx, LLUV_UDP_NAME" expected");

  return handle;
}

static int lluv_check_addr(lua_State *L, int i, struct sockaddr_storage *sa){
  const char *addr  = luaL_checkstring(L, i);
  lua_Integer port  = luaL_checkint(L, i + 1);
  return lluv_to_addr(L, addr, port, sa);
}

static int lluv_udp_bind(lua_State *L){
  lluv_handle_t  *handle = lluv_check_udp(L, 1, LLUV_FLAG_OPEN);
  struct sockaddr_storage sa; int err = lluv_check_addr(L, 2, &sa);
  lua_Integer flags = luaL_optint(L, 4, 0);

  lua_settop(L, 3);

  if(err < 0){
    lua_pushliteral(L, ":");lua_insert(L, -2);lua_concat(L, 3);
    return lluv_fail(L, handle->flags, LLUV_ERR_UV, err, lua_tostring(L, -1));
  }

  err = uv_udp_bind(LLUV_H(handle, uv_udp_t), (struct sockaddr *)&sa, flags);
  if(err < 0){
    lua_settop(L, 3);
    lua_pushliteral(L, ":");lua_insert(L, -2);lua_concat(L, 3);
    return lluv_fail(L, handle->flags, LLUV_ERR_UV, err, lua_tostring(L, -1));
  }

  lua_settop(L, 1);
  return 1;
}

//{ Send

static int lluv_udp_try_send(lua_State *L){
  lluv_handle_t *handle = lluv_check_udp(L, 1, LLUV_FLAG_OPEN);
  struct sockaddr_storage sa; int err = lluv_check_addr(L, 2, &sa);
  size_t len; const char *str = luaL_checklstring(L, 4, &len);
  uv_buf_t buf = uv_buf_init((char*)str, len);

  if(err < 0){
    lua_settop(L, 3);
    lua_pushliteral(L, ":");lua_insert(L, -2);lua_concat(L, 3);
    return lluv_fail(L, handle->flags, LLUV_ERR_UV, err, lua_tostring(L, -1));
  }

  lluv_check_none(L, 3);

  err = uv_udp_try_send(LLUV_H(handle, uv_udp_t), &buf, 1, (struct sockaddr*)&sa);
  if(err < 0){
    return lluv_fail(L, handle->flags, LLUV_ERR_UV, err, NULL);
  }

  lua_pushinteger(L, err);
  return 1;
}

static void lluv_on_udp_send_cb(uv_udp_send_t* arg, int status){
  lluv_udp_send_t  *req = arg->data;
  lluv_handle_t *handle = req->handle;
  lua_State *L          = handle->L;

  LLUV_CHECK_LOOP_CB_INVARIANT(L);

  /* release write data (e.g. Lua string */
  lua_pushnil(L);
  lua_rawsetp(L, LLUV_LUA_REGISTRY, &req->req);

  if(!IS_(handle, OPEN)){
    lluv_udp_send_free(L, req);
    return;
  }

  lua_rawgeti(L, LLUV_LUA_REGISTRY, req->cb);
  lluv_udp_send_free(L, req);
  assert(!lua_isnil(L, -1));

  lluv_handle_pushself(L, handle);
  if(status >= 0) lua_pushnil(L);
  else lluv_error_create(L, LLUV_ERR_UV, (uv_errno_t)status, NULL);

  lluv_lua_call(L, 2, 0);

  LLUV_CHECK_LOOP_CB_INVARIANT(L);
}

static int lluv_udp_send(lua_State *L){
  lluv_handle_t  *handle = lluv_check_udp(L, 1, LLUV_FLAG_OPEN);
  struct sockaddr_storage sa; int err = lluv_check_addr(L, 2, &sa);
  size_t len; const char *str = luaL_checklstring(L, 4, &len);
  uv_buf_t buf = uv_buf_init((char*)str, len);
  lluv_udp_send_t *req;

  if(err < 0){
    lua_settop(L, 3);
    lua_pushliteral(L, ":");lua_insert(L, -2);lua_concat(L, 3);
    return lluv_fail(L, handle->flags, LLUV_ERR_UV, err, lua_tostring(L, -1));
  }

  lluv_check_args_with_cb(L, 5);
  req = lluv_udp_send_new(L, handle);

  lua_rawsetp(L, LLUV_LUA_REGISTRY, &req->req); /* string */

  err = uv_udp_send(&req->req, LLUV_H(handle, uv_udp_t), &buf, 1, (struct sockaddr*)&sa, lluv_on_udp_send_cb);
  if(err < 0){
    lua_pushnil(L);
    lua_rawsetp(L, LLUV_LUA_REGISTRY, &req->req);
    lluv_udp_send_free(L, req);
    return lluv_fail(L, handle->flags, LLUV_ERR_UV, err, NULL);
  }

  lua_settop(L, 1);
  return 1;
}

//}

//{ Recv

static void lluv_on_udp_recv_cb(uv_udp_t *arg, ssize_t nread, const uv_buf_t* buf, const struct sockaddr* addr, unsigned flags){
  lluv_handle_t *handle = lluv_handle_byptr((uv_handle_t*)arg);
  lua_State *L = handle->L;

  LLUV_CHECK_LOOP_CB_INVARIANT(L);

  if((nread == 0) && (addr == NULL)){
    /*
    ** The receive callback will be called with 
    ** nread == 0 and addr == NULL when there is 
    ** nothing to read
    */
    lluv_free_buffer((uv_handle_t*)arg, buf);
    return;
  }

  lua_rawgeti(L, LLUV_LUA_REGISTRY, LLUV_READ_CB(handle));
  assert(!lua_isnil(L, -1));

  lluv_handle_pushself(L, handle);
  
  if(nread >= 0){
    assert(addr);
    lua_pushnil(L);
    lua_pushlstring(L, buf->base, nread);
    lluv_free_buffer((uv_handle_t*)arg, buf);
  }
  else{
    lluv_free_buffer((uv_handle_t*)arg, buf);

    /* The callee is responsible for stopping closing the stream 
     *  when an error happens by calling uv_read_stop() or uv_close().
     *  Trying to read from the stream again is undefined.
     */
    uv_udp_recv_stop(arg);

    luaL_unref(L, LLUV_LUA_REGISTRY, LLUV_READ_CB(handle));
    LLUV_READ_CB(handle) = LUA_NOREF;

    lluv_error_create(L, LLUV_ERR_UV, (uv_errno_t)nread, NULL);
    lua_pushnil(L);
  }
  lua_pushinteger(L, flags);

  lluv_lua_call(L, 4 + lluv_push_addr(L, (const struct sockaddr_storage*)addr), 0);

  LLUV_CHECK_LOOP_CB_INVARIANT(L);
}

static int lluv_udp_start_recv(lua_State *L){
  lluv_handle_t *handle = lluv_check_udp(L, 1, LLUV_FLAG_OPEN);
  int err;

  lluv_check_args_with_cb(L, 2);
  LLUV_READ_CB(handle) = luaL_ref(L, LLUV_LUA_REGISTRY);

  err = uv_udp_recv_start(LLUV_H(handle, uv_udp_t), lluv_alloc_buffer_cb, lluv_on_udp_recv_cb);
  if(err < 0){
    return lluv_fail(L, handle->flags, LLUV_ERR_UV, err, NULL);
  }

  lua_settop(L, 1);
  return 1;
}

static int lluv_udp_stop_recv(lua_State *L){
  lluv_handle_t *handle = lluv_check_udp(L, 1, LLUV_FLAG_OPEN);
  int err;

  lluv_check_none(L, 2);

  err = uv_udp_recv_stop(LLUV_H(handle, uv_udp_t));
  if(err < 0){
    return lluv_fail(L, handle->flags, LLUV_ERR_UV, err, NULL);
  }

  luaL_unref(L, LLUV_LUA_REGISTRY, LLUV_READ_CB(handle));
  LLUV_READ_CB(handle) = LUA_NOREF;

  lua_settop(L, 1);
  return 1;
}

  
//}

static int lluv_udp_getsockname(lua_State *L){
  lluv_handle_t *handle = lluv_check_udp(L, 1, LLUV_FLAG_OPEN);
  struct sockaddr_storage sa; int sa_len = sizeof(sa);
  int err = uv_udp_getsockname(LLUV_H(handle, uv_udp_t), (struct sockaddr*)&sa, &sa_len);

  lua_settop(L, 1);
  if(err < 0){
    return lluv_fail(L, handle->flags, LLUV_ERR_UV, err, NULL);
  }
  return lluv_push_addr(L, &sa);
}


static int lluv_udp_set_membership(lua_State *L){
  lluv_handle_t  *handle = lluv_check_udp(L, 1, LLUV_FLAG_OPEN);
  const char *multicast_addr = luaL_checkstring(L, 2);
  const char *interface_addr = luaL_checkstring(L, 3);
  uv_membership membership   = (uv_membership)luaL_checkint(L, 4);

  int err = uv_udp_set_membership(LLUV_H(handle, uv_udp_t), multicast_addr, interface_addr, membership);
  if(err < 0){
    return lluv_fail(L, handle->flags, LLUV_ERR_UV, err, NULL);
  }

  lua_settop(L, 1);
  return 1;
}

static int lluv_udp_set_multicast_loop(lua_State *L){
  lluv_handle_t  *handle = lluv_check_udp(L, 1, LLUV_FLAG_OPEN);
  int enable = lua_toboolean(L, 2);

  int err = uv_udp_set_multicast_loop(LLUV_H(handle, uv_udp_t), enable);
  if(err < 0){
    return lluv_fail(L, handle->flags, LLUV_ERR_UV, err, NULL);
  }

  lua_settop(L, 1);
  return 1;
}

static int lluv_udp_set_multicast_ttl(lua_State *L){
  lluv_handle_t  *handle = lluv_check_udp(L, 1, LLUV_FLAG_OPEN);
  int ttl = luaL_checkint(L, 2);

  int err = uv_udp_set_multicast_ttl(LLUV_H(handle, uv_udp_t), ttl);
  if(err < 0){
    return lluv_fail(L, handle->flags, LLUV_ERR_UV, err, NULL);
  }

  lua_settop(L, 1);
  return 1;
}

static int lluv_udp_set_multicast_interface(lua_State *L){
  lluv_handle_t  *handle = lluv_check_udp(L, 1, LLUV_FLAG_OPEN);
  const char *interface_addr = luaL_checkstring(L, 2);

  int err = uv_udp_set_multicast_interface(LLUV_H(handle, uv_udp_t), interface_addr);
  if(err < 0){
    return lluv_fail(L, handle->flags, LLUV_ERR_UV, err, NULL);
  }

  lua_settop(L, 1);
  return 1;
}

static int lluv_udp_set_broadcast(lua_State *L){
  lluv_handle_t  *handle = lluv_check_udp(L, 1, LLUV_FLAG_OPEN);
  int enable = lua_toboolean(L, 2);

  int err = uv_udp_set_broadcast(LLUV_H(handle, uv_udp_t), enable);
  if(err < 0){
    return lluv_fail(L, handle->flags, LLUV_ERR_UV, err, NULL);
  }

  lua_settop(L, 1);
  return 1;
}

static int lluv_udp_set_ttl(lua_State *L){
  lluv_handle_t  *handle = lluv_check_udp(L, 1, LLUV_FLAG_OPEN);
  int ttl = luaL_checkint(L, 2);

  int err = uv_udp_set_ttl(LLUV_H(handle, uv_udp_t), ttl);
  if(err < 0){
    return lluv_fail(L, handle->flags, LLUV_ERR_UV, err, NULL);
  }

  lua_settop(L, 1);
  return 1;
}

static const struct luaL_Reg lluv_udp_methods[] = {
  { "bind",                     lluv_udp_bind                    },
  { "try_send",                 lluv_udp_try_send                },
  { "send",                     lluv_udp_send                    },
  { "getsockname",              lluv_udp_getsockname             },
  { "start_recv",               lluv_udp_start_recv              },
  { "stop_recv",                lluv_udp_stop_recv               },
  { "set_membership",           lluv_udp_set_membership          },
  { "set_multicast_loop",       lluv_udp_set_multicast_loop      },
  { "set_multicast_ttl",        lluv_udp_set_multicast_ttl       },
  { "set_multicast_interface",  lluv_udp_set_multicast_interface },
  { "set_broadcast",            lluv_udp_set_broadcast           },
  { "set_ttl",                  lluv_udp_set_ttl                 },

  {NULL,NULL}
};

static const lluv_uv_const_t lluv_udp_constants[] = {
  { UV_UDP_IPV6ONLY,   "UDP_IPV6ONLY"   },
  { UV_UDP_PARTIAL,    "UDP_PARTIAL"    },
  { UV_UDP_REUSEADDR,  "UDP_REUSEADDR"  },
  { UV_LEAVE_GROUP ,   "LEAVE_GROUP "   },
  { UV_JOIN_GROUP,     "JOIN_GROUP"     },

  { 0, NULL }
};

static const struct luaL_Reg lluv_udp_functions[] = {
  { "udp", lluv_udp_create },

  {NULL,NULL}
};

LLUV_INTERNAL void lluv_udp_initlib(lua_State *L, int nup){
  lutil_pushnvalues(L, nup);
  if(!lutil_createmetap(L, LLUV_UDP, lluv_udp_methods, nup))
    lua_pop(L, nup);
  lua_pop(L, 1);

  luaL_setfuncs(L, lluv_udp_functions, nup);
  lluv_register_constants(L, lluv_udp_constants);
}
