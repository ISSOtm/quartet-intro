
ASFLAGS := -p 0xFF -Wall -Wextra -hL -i src/
LDFLAGS := -d -t
FIXFLAGS:= -v

RGBDS   ?=
RGBASM  ?= $(RGBDS)rgbasm
RGBLINK ?= $(RGBDS)rgblink
RGBFIX  ?= $(RGBDS)rgbfix
RGBGFX  ?= $(RGBDS)rgbgfx


BINDIR := bin
OBJDIR := obj
RESDIR := res
DEPDIR := dep


VPATH := src

SRCS := $(wildcard src/*.asm)
OBJS := $(patsubst src/%.asm,$(OBJDIR)/%.o,$(SRCS))
DEPS := $(patsubst src/%.asm,$(DEPDIR)/%.mk,$(SRCS))


all: $(BINDIR)/quartet.gb
.PHONY: all

clean:
	rm -rf $(BINDIR) $(OBJDIR) $(RESDIR) $(DEPDIR)
.PHONY: all

# We rely on `quartet.gb` being first, and thus being passed to `-O`
# For some reason, RGBLINK outputs too many bytes?
$(BINDIR)/quartet.gb $(BINDIR)/quartet.sym $(BINDIR)/quartet.map: quartet.gb $(OBJS)
	@mkdir -p $(@D)
	$(RGBLINK) $(LDFLAGS) -o $(BINDIR)/quartet.gb -n $(BINDIR)/quartet_tmp.sym -m $(BINDIR)/quartet.map -O $^
	truncate -cs 32768 $(BINDIR)/quartet.gb
	$(RGBFIX) $(FIXFLAGS) $(BINDIR)/quartet.gb
	sed 's/ / Q_/' quartet.sym | cat $(BINDIR)/quartet_tmp.sym - > $(BINDIR)/quartet.sym

$(OBJDIR)/%.o $(DEPDIR)/%.mk: src/%.asm
	@mkdir -p $(OBJDIR) $(DEPDIR)
	$(RGBASM) $(ASFLAGS) -M $(DEPDIR)/$*.mk -MG -MP -MQ $(OBJDIR)/$*.o -MQ $(DEPDIR)/$*.mk -o $(OBJDIR)/$*.o $<

$(RESDIR)/syms.asm: tools/syms.sh quartet.sym
	@mkdir -p $(RESDIR)
	$^ > $@

$(RESDIR)/%.2bpp: $(RESDIR)/%.png
	@mkdir -p $(RESDIR)
	$(RGBGFX) -o $@ $<

ifeq ($(filter clean,$(MAKECMDGOALS)),)
-include $(DEPS)
endif