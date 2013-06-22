//original file from https://github.com/Baughn/Dwarf-Fortress--libgraphics-
#include "tinythread.h"
#include "fast_mutex.h"

#include "Core.h"
#include <VTableInterpose.h>
#include "df/renderer.h"
#include "df/init.h"
#include "df/enabler.h"
#include "df/zoom_commands.h"
#include "df/texture_handler.h"
#include "df/graphic.h"

using df::renderer;
using df::init;
using df::enabler;

struct old_opengl:public renderer
{
    void* sdlSurface;
    int32_t dispx,dispy;
    float *vertexes, *fg, *bg, *tex;
    int32_t zoom_steps,forced_steps,natural_w,natural_h;
    int32_t off_x,off_y,size_x,size_y;
};
struct renderer_wrap : public renderer {
private:
    void set_to_null() {
        screen = NULL;
        screentexpos = NULL;
        screentexpos_addcolor = NULL;
        screentexpos_grayscale = NULL;
        screentexpos_cf = NULL;
        screentexpos_cbr = NULL;
        screen_old = NULL;
        screentexpos_old = NULL;
        screentexpos_addcolor_old = NULL;
        screentexpos_grayscale_old = NULL;
        screentexpos_cf_old = NULL;
        screentexpos_cbr_old = NULL;
    }

    void copy_from_inner() {
        screen = parent->screen;
        screentexpos = parent->screentexpos;
        screentexpos_addcolor = parent->screentexpos_addcolor;
        screentexpos_grayscale = parent->screentexpos_grayscale;
        screentexpos_cf = parent->screentexpos_cf;
        screentexpos_cbr = parent->screentexpos_cbr;
        screen_old = parent->screen_old;
        screentexpos_old = parent->screentexpos_old;
        screentexpos_addcolor_old = parent->screentexpos_addcolor_old;
        screentexpos_grayscale_old = parent->screentexpos_grayscale_old;
        screentexpos_cf_old = parent->screentexpos_cf_old;
        screentexpos_cbr_old = parent->screentexpos_cbr_old;
    }

    void copy_to_inner() {
        parent->screen = screen;
        parent->screentexpos = screentexpos;
        parent->screentexpos_addcolor = screentexpos_addcolor;
        parent->screentexpos_grayscale = screentexpos_grayscale;
        parent->screentexpos_cf = screentexpos_cf;
        parent->screentexpos_cbr = screentexpos_cbr;
        parent->screen_old = screen_old;
        parent->screentexpos_old = screentexpos_old;
        parent->screentexpos_addcolor_old = screentexpos_addcolor_old;
        parent->screentexpos_grayscale_old = screentexpos_grayscale_old;
        parent->screentexpos_cf_old = screentexpos_cf_old;
        parent->screentexpos_cbr_old = screentexpos_cbr_old;
    }
public:
    renderer_wrap(renderer* parent):parent(parent)
    {
        copy_from_inner();
    }
    virtual void update_tile(int32_t x, int32_t y) { 

        copy_to_inner();
        parent->update_tile(x,y);
    };
    virtual void update_all() { 
        copy_to_inner();
        parent->update_all();
    };
    virtual void render() { 
        copy_to_inner();
        parent->render();
    };
    virtual void set_fullscreen() { 
        copy_to_inner();
        parent->set_fullscreen();
    };
    virtual void zoom(df::zoom_commands z) { 
        copy_to_inner();
        parent->zoom(z);
    };
    virtual void resize(int32_t w, int32_t h) { 
        copy_to_inner();
        parent->resize(w,h);
        copy_from_inner();
    };
    virtual void grid_resize(int32_t w, int32_t h) { 
        copy_to_inner();
        parent->grid_resize(w,h);
        copy_from_inner();
    };
    virtual ~renderer_wrap() { 
        df::global::enabler->renderer=parent;
    };
    virtual bool get_mouse_coords(int32_t* x, int32_t* y) { 
        return parent->get_mouse_coords(x,y);
    };
    virtual bool uses_opengl() { 
        return parent->uses_opengl();
    };
protected:
    renderer* parent;
};
struct renderer_trippy : public renderer_wrap {
private:
    float rFloat()
    {
        return rand()/(float)RAND_MAX;
    }
    void colorizeTile(int x,int y)
    {
        const int tile = x*(df::global::gps->dimy) + y;
        old_opengl* p=reinterpret_cast<old_opengl*>(parent);
        float *fg = p->fg + tile * 4 * 6;
        float *bg = p->bg + tile * 4 * 6;
        float *tex = p->tex + tile * 2 * 6;
        const float val=1/2.0;
        
        float r=rFloat()*val - val/2;
        float g=rFloat()*val - val/2;
        float b=rFloat()*val - val/2;

        float backr=rFloat()*val - val/2;
        float backg=rFloat()*val - val/2;
        float backb=rFloat()*val - val/2;
        for (int i = 0; i < 6; i++) {
            *(fg++) += r;
            *(fg++) += g;
            *(fg++) += b;
            *(fg++) = 1;

            *(bg++) += backr;
            *(bg++) += backg;
            *(bg++) += backb;
            *(bg++) = 1;
        }
    }
public:
    renderer_trippy(renderer* parent):renderer_wrap(parent)
    {
    }
    virtual void update_tile(int32_t x, int32_t y) { 
        renderer_wrap::update_tile(x,y);
        colorizeTile(x,y);
    };
    virtual void update_all() { 
        renderer_wrap::update_all();
        for (int x = 0; x < df::global::gps->dimx; x++)
            for (int y = 0; y < df::global::gps->dimy; y++)
                colorizeTile(x,y);
    };
};
struct renderer_test : public renderer_wrap {
private:
    void colorizeTile(int x,int y)
    {
        const int tile = x*(df::global::gps->dimy) + y;
        old_opengl* p=reinterpret_cast<old_opengl*>(parent);
        float *fg = p->fg + tile * 4 * 6;
        float *bg = p->bg + tile * 4 * 6;
        float *tex = p->tex + tile * 2 * 6;
        float v=opacity[tile];
        for (int i = 0; i < 6; i++) {
            *(fg++) *= v;
            *(fg++) *= v;
            *(fg++) *= v;
            *(fg++) = 1;

            *(bg++) *= v;
            *(bg++) *= v;
            *(bg++) *= v;
            *(bg++) = 1;
        }
    }
    void reinitOpacity(int w,int h)
    {
        tthread::lock_guard<tthread::fast_mutex> guard(dataMutex);
        opacity.resize(w*h);
    }
    void reinitOpacity()
    {
        reinitOpacity(df::global::gps->dimy,df::global::gps->dimx);
    }
public:
    tthread::fast_mutex dataMutex;
    std::vector<float> opacity;
    renderer_test(renderer* parent):renderer_wrap(parent)
    {
        reinitOpacity();
    }
    virtual void update_tile(int32_t x, int32_t y) { 
        renderer_wrap::update_tile(x,y);
        tthread::lock_guard<tthread::fast_mutex> guard(dataMutex);
        colorizeTile(x,y);
        //some sort of mutex or sth?
        //and then map read
    };
    virtual void update_all() { 
        renderer_wrap::update_all();
        tthread::lock_guard<tthread::fast_mutex> guard(dataMutex);
        for (int x = 0; x < df::global::gps->dimx; x++)
            for (int y = 0; y < df::global::gps->dimy; y++)
                colorizeTile(x,y);
        //some sort of mutex or sth?
        //and then map read
        //same stuff for all of them i guess...
    };
    virtual void grid_resize(int32_t w, int32_t h) { 
        renderer_wrap::grid_resize(w,h);
        reinitOpacity(w,h);
    };
    virtual void resize(int32_t w, int32_t h) {
        renderer_wrap::resize(w,h);
        reinitOpacity(w,h);
    }
};