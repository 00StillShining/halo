# halo — EP-40 Riddim 3D model generator (Blender headless -> USDZ).
#
#   /Applications/Blender.app/Contents/MacOS/Blender --background \
#       --python tools/blender/build_ep40.py -- <out.usdz>
#
# Procedural geometry built from measured observations of the EP-40 Riddim.
# At the owner's explicit direction, this private/personal asset reproduces the
# face lettering and the official 66-indicator screen diagram.  The diagram is
# embedded here as a deterministic fallback texture, not a product photograph.
#
# PORTRAIT device, meters, Blender Z-up (export converts to Y-up):
#   X = width     = 0.176 m   (u: 0 left  -> 1 right)
#   Y = depth     = 0.240 m   (v: 0 near  -> 1 far ; branding/speaker are FAR)
#   Z = thickness = 0.016 m   (up ; controls protrude in +Z)
import bpy, sys, math, zipfile, base64, os, tempfile
from array import array

W, D, TH = 0.176, 0.240, 0.016
TOP = TH / 2.0
TOP_FACE = TOP + 0.0014
CONTROL_BASE = TOP_FACE + 0.0002
MIN_LEGEND_SIZE = 0.0021

PAD_SIZE = 0.0167
GRID_COLS = (0.367, 0.505, 0.643)
GRID_ROWS = (0.395, 0.295, 0.196, 0.098)
GROUP_U = 0.229
RIGHT_COLS = (0.771, 0.910)

def u(uu): return (uu - 0.5) * W          # normalised width  -> x
def v(vv): return (vv - 0.5) * D          # normalised depth   -> y

# ---------------------------------------------------------------- scene reset
def reset():
    global _legend_n
    bpy.ops.object.select_all(action='SELECT')
    bpy.ops.object.delete()
    for coll in (bpy.data.meshes, bpy.data.curves, bpy.data.images,
                 bpy.data.materials, bpy.data.objects):
        for d in list(coll):
            try: coll.remove(d)
            except Exception: pass
    OBJS.clear()
    _legend_n = 0
    bpy.context.scene.world = None        # no DomeLight baked into the USD

# ---------------------------------------------------------------- materials
def mat(name, rgb, rough=0.6, metal=0.0):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes.get("Principled BSDF")
    b.inputs["Base Color"].default_value = (*rgb, 1.0)
    b.inputs["Roughness"].default_value = rough
    if "Metallic" in b.inputs: b.inputs["Metallic"].default_value = metal
    return m

M = {}
def build_materials():
    # Values are intentionally separated in luminance: RealityKit's stage lights
    # otherwise flatten the warm chassis and key faces into a single white mass.
    M['body']   = mat("m_body",   (0.52, 0.48, 0.38), 0.78)
    M['plate']  = mat("m_plate",  (0.60, 0.56, 0.46), 0.70)
    M['edge']   = mat("m_edge",   (0.30, 0.31, 0.29), 0.46, 0.28)
    M['cap']    = mat("m_cap",    (0.76, 0.73, 0.65), 0.48)
    M['brand']  = mat("m_brand",  (0.88, 0.86, 0.79), 0.62)
    M['brandG'] = mat("m_brandG", (0.010, 0.115, 0.068), 0.60)
    M['brandO'] = mat("m_brandO", (0.970, 0.145, 0.028), 0.58)
    M['brandI'] = mat("m_brandI", (0.24, 0.29, 0.26), 0.62)
    M['green']  = mat("m_green",  (0.018, 0.145, 0.088), 0.54)
    M['greenC'] = mat("m_greenC", (0.028, 0.205, 0.125), 0.48)
    M['greenD'] = mat("m_greenD", (0.006, 0.072, 0.043), 0.58)
    M['orange'] = mat("m_orange", (0.950, 0.082, 0.010), 0.52)
    M['orangeC']= mat("m_orangeC",(1.000, 0.145, 0.018), 0.47)
    M['dark']   = mat("m_dark",   (0.010, 0.014, 0.013), 0.58)
    M['ink']    = mat("m_ink",    (0.025, 0.031, 0.029), 0.52)
    M['legendG']= mat("m_legendG",(0.010, 0.105, 0.061), 0.52)
    M['legendL']= mat("m_legendL",(0.78, 0.76, 0.68), 0.55)
    M['legendO']= mat("m_legendO",(0.920, 0.060, 0.006), 0.52)


_SCREEN_ART_B85 = (
    "iBL{Q4GJ0x0000DNk~Le000C40003Y2m=5B0M-j4g#Z8mz)(z7MfLaj^78ZR=HubXxy;4D%*4UW#K6qNzstqH>cOJoz@OE@ui?C%"
    "r^UCAw5edZn_I4wIj)8=sD3f0elMqeE~<bor+zM{eJ-bbB&>lbr+mJXd1sQ2Ux|HQf^b!to>i2$Q<Sz-l(kZnwNjL?QID!HrhF--"
    "dL^WIAf$IXj%+ZAUNVPdCyrv_XFugzGuT@y*jp*sTPWX4E9X5b+dU}TJSf{dC)+$G**z!TH6UkrV#ib{AW$wDNF)|TAx;tVGynj%"
    "cS%G+RCwC$T@6Fx$g)+?5tMuf2wyWeIwWCSa71@dXJ`Nazj~*tJ4q+$gy1-P-@Ti9@9roHLeh1*y6V)alW}XUwf3*IllBs{)>;by"
    "t+m!#3jnRP)>;byt+m!#3jnRP)>;byt+m!#3jnRP)>;byt+m!#3jnRP)>;byt+m!#3jnRP)>;byt+m!#3jnRP)>;byt+m!#3jnRP"
    ")>;byt+m!#3jnRP)>;byt+m!#3jnRP)>;byt+m!#3jnRP)>;byt+m!#3jnRP)>;byt+m!#3jnRP)>;byt+m!#3jnRP)>;byt+m!#"
    "3jnRP)>;byt+m!#3jnRP)>;byt+m!#3jnRP)>;byt+m!#3jnRP)>;byt+m!#3jnRP)&f9lt+mzyKx?hF)&f9lt+mzyKx?hF)&f9l"
    "t+mzyKx?hF)&f9lt+mzyKx?hF)&f9lt+mzyKx?hF)&f9lt+mzyKx?hF)&f9lt+mzyKx?hF)&f9lt+mzyKx?hF)&f9lt+mzyKx?hF"
    ")&f9lt+mzyKx?hF)&f9lt+mzyKx?hF_TK{lF08$h?_+*@CABN;mtP_X+spV)0N{H53g+{Ar7vPwKwkyo!Sbs1o4vC4&d#)|F~4f5"
    "c^=+xoq6x+qlMRUqmUo*TNun;l}J3`=a%77{y%hrgMZZXv`fXSy&GP|vsRw>|K)1d`N7HYuNKAA32eH;Wt|R(!>MJOrbAy1C!y|I"
    "`C;g$?&Bur`$56nsENlk_6<Lr;2q_Szvp*4)xM4!#Sy)WX{C+FSdD&Z?Uc+D<|?08w=Sb(QS)nhv27Cq_{w$k>(`&_|M%IUd+3MK"
    ";RO=7p>4(d#Z>v&aTGLPwYacXk$b>Pu#ZhA8jHhfSN2x<Ck@$nolWD_+i~3Y-)#?AMe<!~?N|WtrxVLwEIxkxXb*jVYR)#B9~-vW"
    "Y&MuX<W~jg^FxOqVo7FZwv_hyR@&0E-0FMk!xIQ<qmaSXJGe>W&zgh5?BmCUG`#1<6&?|0Yp}}qW81Q=v$L~arJbEwc3gNa7A$b1"
    "#$x(;Q2v8~YXy<GS`l8;k1f-}@8MrtE>{=mSr@zp(SM_b{((COhxbz?aATuu0d+(7%;9JHZV(M^!>)2^JlD%Do$+ci+e}vVyM<%f"
    "_MDeV-WIk~i5-44wD2VHi&x3of+x&AF6P!Sd}9!R&lg6eNaIi}QWg8yvl=@R0Nj{dezV<fA2#!N<qUQYs_kZO;0N&}_dZ9VvAnrn"
    "F0Zd|GP}NBmh8qfD{tv445o1mT(um+<TxIOLH*@eP3Dg;FE5X(y`=VN#-*F%2V>)`dw$5e=Z2G8!EWf9#sTY@jvKnA<zpL`6OMeW"
    "Z3A0>XqjJ@X5fd`(j+W&gD?V&nU%2U2af$;XjXkV?#5Qf!l4rJm~F(a7n}V-cNDl&vrDiIB#5V0uiqO66(`O(9LMR;e4PIAiklyG"
    "0N_s@v95QIW!ui&3QzVU3r`bIddb`4Zo8S;(HoA7ZWu(4?bv?qB6%UlB1c1t7nz%v8aoaEfXy>@`ETFuA7)NCoITvD_ONlL!O)x!"
    ")jJb7%bU;G=Wp=e&%Eb<79en|+LxQpH%l|}^zI)|9M?9@*(<R1^>sEg&6VTCwO3;`d3}6-dWP-Ep4pzHJ#X#u8Ni<!-HYBu??b)y"
    "dL1)%)r;abfQ|F65tbHg=-e*h`GHGrj^n?1^ZAQu#g1`f2DHvy#{?Ewkym+lZNvO8G@~{IfV=iDO(%5e3p*nJzw8^+*zWd$2e>Sb"
    "Y4k7qxtow%q=xNd_g%TdorVr=2HTBQ?Tz?DGj<2LPM)4q!vilbGe`f1gQ0kuTw8m*fLvg5m#K|9s$x2a+<#%4>fdx@8;jq>q7PO_"
    "fePH<C0+I!I}!lAiLoW0Cji*kVLZoo-%?{xSPeJ1XbVBZ^7iwMX`FXbE4zn*DB<(+llD4$(Zr&_198U|@Ux?T>Buq1)u;_twl7cL"
    "zkmOeKj@#|6?=Y}O>|G~U3_R@y${APQ1b@nd9Qb&nsQ{w9yvF{@+bSWyfw`*jBp~dT=N<jd2Pnl@^%S$b1VxFe=+UIuLgi}$ogMk"
    "=BOS3%<iDyb0crm>vt{p>hkh((6t>rc;&=X$L#j|gF&~#DJk5a;s2dU==uICc4h-Ra%Mj^R_xa7YcJ1m-|tu_Pfy<&3Z7`~>|b_I"
    "FHbKUTl=?oiGAPAX5aTu-{JFEm0P?DeZ3jX@XXmTIL`b1VC34?di@n<kMdBneb`b^F`Pu+aa;Dw^Y>~yIW7Q*a4DtBKimV9&5a5G"
    "4_kBM#nyJC-W#Cn^5)h&Jvm^V<<0Vw?z3TgoNcyz#Q4T>#y5H3*lf&c4Z;S_h5?{#PcK`$yc%#j&kMW%8QXag0WLb~2lQg&ymuHj"
    "&U)vit=x;~+ANV(z`skvz|Ry1EpPB2_I`v(OU+?L0f6~`B>+ro0U)xvgF(M*#_<(`fAarJga8Nx27Sxw;jzIb1pt24o(E@lusEE_"
    "bULwT+nEDLrM0=LzKolfJskOI|0mpkPbsaPaOBx(hkoQ}-|%X(czph|dvY>+!JfbAcTP_`-NEkVX}{~7oDA?n!_|@gADK3LKWsh9"
    "`|$%W{LRd?r_ECVxR$dDFE}0ma8NRb3Ifa~Q4Rp;1P}(!>^TRvw8(F7&QDGc*okqwymj@6zWpJ>4#nue@vw1fV#(FSc+_Lx^W#jj"
    "7--{B9r^4-x})Rk8~~gte-{VUvu1(Axe=GDesFejebdB0d`2P!K+1$+;Pz&T@9gT&_`eANfYhr#T%3LWGO<2=J-F)kFX=HrLB)oS"
    "CBNAr1lVm6G21gN(0T0OzYnv@#e#*s-S7M4vrqf|tc%U+v@_Vy){if{Py45}){`l`-fvD$Pr7^Yt70d^v0#Js3;_6X8~`9EWZr#E"
    "%qauFH(K=D*%1ivt^hz8Kpe>|;q<toR$Ksp*>Hu2DBAM!0I=+w9t42SlFq-b4xWD$yk9~90HCHAKr2D}*>SUUYoQ1L7a!!I<^1gI"
    ";^M3l0Aj1#dn*9&@#q=>((?BDb7Hp~2z+5UzzM<m*8zY(B>;fWcl(!_F%~3<(7zg0SNyO7ZTyE~MA|bs0Juj8P!&qiPL53*`}gi;"
    "hYg*V<H;#GGQRF?=`inW!)qW0ZT9T)_*DZ3-BbE@KRBVt;m6QFF2c4KssHDW00{uls{gjzG(TB*?+gH2%KQx^0Br1dr~m*xFj?V^"
    "(hrUYfYVa~fO4XSKKoYW8kOB&1OUb)^6T;++T#xbH0@Hz0RUY7ymQK+j&}wSP$8fY0lXamWP()seBPEa9QYLY<9{6h^!l04YYj=k"
    "$`inhwtIw)6f)o6Z*dUk74(38Nne>?P1e}L2NVIo|C76Za<X|L@9yuPAA7n5!{=*0?tkC!@x0FR_RAMq>2xH(8RF^X$Mi@5aMp(a"
    "fc?yj-Tx2(Y_{e!5+MK}bv_x+asXgOQyZYWnJb4~mjR%G|DT$a?{YO&9pnI%6hM*#poEBR*M4|g7Xs)H00jVG_gBJ`(~cVFzZ(D`"
    "`(Ji_)hGqvR<c4W0pRs7y}cfC&5GyUz43Wp-v|I_{mWWIPB1QTs|3f00|0V%o5FrBOrfHPy2?f%fVOaiA^~FmC*%Nt0=U~qNp}bV"
    "C?KH3z;k5;z=!`ALIL)F9OgP4%<lG-MSN-Msq%xMs%TdNz(4^2M{Wv-=|b-c03JpBviQeuWH8JFz-;0%{B9SDhq>`l0N|Cb^4NAz"
    "_~9ymARAB(U^AQBlNiO4x=JfHgK`#tbGqIE0J!L!%B00f^6%++h5)^M4&eN)06=7=o2AzCi8#R#fE|Gf6b45D!0XSy_4e}s0{m6+"
    "yua_>_`I*j1AvdJuXPXrz&(v~6e+MYi8F<A8I~m0;?+H`maT!P)TYxbA;8>;G*z_Kq=#f4^7nLhr*-({c6olv$N2A55BR><<^Ti$"
    "eCMhk!Uy9E++Us_2pGOM1pwER<$a=cC;*@wZ@K<{pPjS=L0-fMb{pgX-m47A0I)^sF9`u=)8SPL0CdP2hK#%0j|Bku(i{N%5?Rh%"
    "*tP>_Hx~=y@quJDw~^tUOl>4g?V9SYHVeRa#Ty?0fKHOLL<%5%f9J_5;9La&@9h8pPHZI407wAJnEyt8f6GaL8^iG&n4Tk90RXRm"
    "{ryvKf7izVmCyV6^X_fW(<49)0Du$~4;?di_#X^%sQ{4-=o+T$sFiZQPS`0P#Nyo1HnE{ItJ~`uo<smt2jd{nri+CipPpbDo{QU#"
    "{2x7vYT$ZO4FF_&ESP1M=|1Vx;|&48i>8hvc%n!OXJ-IQ&2J&!C;{L;sb_#1gwGovNHcn%!#utd5y+!t3T58KzRyX3#r8o-0Yo@?"
    "acH1Wy?zw{91|50%d|tm1Qa~L5lC{JFqvC*m)K)2fC>Rm2<IwNvl#$fr2Y@5&wV2h01GPns|5f6r{PSsN&rAt5tu%%NdRy|nSYV{"
    "W1<w*0!_mtED-$Zb3M*g06>i&|NYn7{J-{jU#p+@^XG8@;D;zR8A<X_IDWU=&9VVV42qu)`u%=Zj-}1%9?Vv%7gGR$jcQJp5Lu-N"
    "xAojuaq^nWXv1O-EvXkhy`U1%;gYq?OYek(9{>O@`*m)ObfIwNpdkPtNVl=PT}FV=SsVrcQDpN_kAqp0`i=uc73M4b;zn=B0RVVE"
    "-+(^^1Tq<6ZyuD$B;s$=7$wbg{{jGv$Bc<<U;v0Q!ff#7e8-~47j`YFY=y($%U%hAUXTE&ct!#MXNt>rPyjeTRbqfL0DwMpuBjZB"
    "ONe;@0LMSFsnm~X|Hh<ZgYlWjkeyQ^M10}JbPjMpMG*90#~uHNBY@X`Bm(e4yGNBi7#Co=aD3W}=?n2Ke<#qPZ={z6XMejld)Pn7"
    "?Vn13F&jeuGvZ(vF4qDC1QbHR)#OS7K$jwUrDVNr1^_P`EEy$fbOZpv|1GTWwLPY0kWe`Tm<0gX-m517ksHUSF%KZX7}R`F3#;rX"
    "0GP}<nd(H+?U4nvQUIVb%S0kW0RYUm1Av+sT`%VL9JW}aSZY#afXAGAR%tl2W;-PW!U-nu#<c)&adxV@yaE6x9UTCSQl=2xT@o7="
    "&SP3a%mD!1YSR?8|0V4mNIZiGakD&SMiebV{9lKDcw<^lbVL&Hudj>ODtG+(y7>B6Wgc%)>B)cJE$*tHSB(IF<GpAwrxE~A2<yw;"
    "o^$aX{(=%R{Y$$3gD&3)>HpL8-lJh~FgWSKCBD%Hv>DiO#BB$zysLD}s6d6#pbh|Vlt2HhcydDk*l#;0rza`^>;>QKAOLtt<!{ZM"
    "a7ZYvD*+%&wXH<4<AIZ$=A^zT=&jJJ##k6??Bpm~F+~96=*byi;KWH5kRuaYKK_0HfM+YEQN>aKs6I{x^#3?f&XW*`ngH?6Lh3!P"
    "<N+iBfCvLSNj0FOgaCyIAOQeW4m8!yPEtQ80)Vl+y%hyN0s!QXI-vcSbREEmIzQ<cR2gMXU}dUD2LSLzLV$`K;Nq?-nnxaw5kQ~I"
    "qgVW^BL4sTugWZ-z?3770Kv2;V|}<g7&)}(pLFpJ{zsnQJ&^!_Zh@h4S-_zI_s>F^>VbVCwhivja3bd{;b9^KpyaVtY6Z^#V1|uc"
    "1$=n~_`aym0qmbTIilOiOymF#0)U@6{M?Et1ULi$bkd$C#SU2%tfd?INU2EE^*SF10I!6wC<F*H5dO9c9Lo9t#L++t0G+o2KxF9w"
    "z>)w^(-+Kb_zqh9DR+SXMrhmy4B{bJ`K%!UK<@aRoHKVsUJxO`StS7Ai6?r7lZ1`j5x|RZ{J&kM0I)O(05}#vB!CFu9LInYV1ePp"
    "u73m%;4jM9Vc*qUv%g+BHmCvsv0v++cPC<s*Q)2i&$Tz{tN8J2a{!?JpCkh44muJ51|10i-3$QiI9CHBkJ!yjbm!5@6zt4%v~_{7"
    "K^Ypdb98Xw<me&^SPGdl0N7F$U){(#f%N=nRPzA7%j7}so^P4~0P248EbC7pK;YVk0Du{d!BE|KYq|scshzecziRAQ01#QoSkMwE"
    "3wX6nP5`q>S|3!YN^WB!Pz3<2wM)xB6aiq1{Y<Geq*zqL^N<>%ZPn8PfIRbeK3wDv|MEND%`eV#eaj*Tp#FL(3b-gI0bPy(mMH)%"
    "Pdei4e{z1K0KiR6GhkH&09RdPG6=8fmkZ&?l>k7I{zCga@v7C&`z!n1j~|QAI|cx-vIPq;1%N*7{t^IAI-L{%@EU$0lZPJlndQt7"
    "6C39jxGTM`8AZki(Ti!gUJ#QkgIirLmOOy`M&1YjHo50@WoqCM0OYd%Yc6Sz(h#5o01wj7@Lu57+lP#PQ`0Six?HhQIcLWMfY|Ge"
    "tvvS6?=yN*7L|+w73OZQmz|T}1pr|+05HEkr$fTB17ypx^gsdt9pSQt?B7KvD+HYPLiOfI0O-`wobj|`8PJU+0)PPt05GKEpArz<"
    "5&&>%38#YULPrSzz9z@<*NhSLcgFt_xq-j<_wvtsmCw6Vp7%53|A-%!pLch+;2&kVKF#w00ACvefR}^-BI;)VAh*A~%no9woB}ZO"
    "A%IVtB9YKyY8;kFHPir%j?pu0Yf7hJXnri*8omgp^Od_ssk|ltP(+SR1^`}j?k`B+lmuAl0bn7cYjFa|B5#hjD=+72>g=*6c#Rzi"
    "09=Y7zfaQr6DREqNLfKlRZ>6ZF#zC|Lc&EI0Mt|gT#G7fOV%Cu!p6b_f_kfA*b4wSmjIBud~%Xc_VP1r1aMXt05EWzmv{g`01A!-"
    "03gw20GH@GAq#kejKDb(QuJnTjY<S40>EEzMB#IP<vcL=9RT32aGw8)?{mK?-TG%f%m4AU@H~9KNM19|2ym`Z;sgH-08n^d9S<N0"
    "0XpRONCNhmg+)M+*`-8)+`>l)fUMXKW$L6m>)e<^g~ghpi8b;9)1XX{PNX9vj6DfXzx4lvL~<AazJI6uVL}~C<AOr~fRu-_zuDw9"
    "{>Z5Z06GEqNg5t0PqgIJoB+Ub-tE7?6B9520CMn&<Xbrc0Perx1dvn&ie%;B_U0D=z^ny;Y90VH5HngG*>%!zg8;w@{E8evN0S3k"
    "g84IT8SpHHi%#yD@@onK%0wVHauEXv06^q_%Z$nM4xRits|+N#mI&ZC0f4{$ZVUi9kL1Ll1^|BkRRn;1CXl`@0f1UG{F(qjA%j@Q"
    "1cU&X0080l`~}tjiU2?eFe;pOx#@2h_5?A50ss$OE98M)7e54(6n$!%KdmrExuPemo07;H006p(XPvYgP=*Ejg8%@r;tT=SygG(v"
    "?Ga%6ihQIOrNK6}<hj+l$<*fX{7wL%G$i00Lhk^czOqtM&_qc~yc+<32(+%K0@xw~sB8yH8f|n8dtF$almR<=4sbI7khQ~(WC5Kg"
    "d?5Tl9x1flfRqQgS>7g9|67yG0U(u%NI;|rZqOv9k8|<>@Ribd4FNzc(BJ)R4gjhr^LGsaAddib0D!QV++LRdITT<VPys+Pfx5Zf"
    "+!uW)cG{hJaR!++Z2q=ooSR9DfQ~t*QpTS^|L^y^-N9y`?(P79$)N}U6qD_sOH_qz3JUw}ycz&lU>fR%(=^0g6Wc4R1L%@~(zQfE"
    "KJ|a!TOq{JuaL@~_%{K-Al>3^2?pjQsr)5}0Sy2we+2-Bc10C{A79rjrNFE}fSaX`SSJDCyf$B12>|CZ;eY-iM*<>FfGi{Ent`D7"
    "giHlR0Q7$*<p7uG6bp!&gJcPsw}xGzm81Xwd0TS;$PnQ5=P>}Fc(Ta<Hw1tj0@U^bcoByH90AZ7KmY(30GtcpG@xh}?&VP&UHt?A"
    "RssNYy(7pho9A5|2Ed8u1c7&`XM}{k*uFn~KLP;0lOouD2N|FY6ZX4m0Pw=;XbdtK5Wuw4_8*@LgSMUtxV@K>8-A(|z{GqPvcD6{"
    "iUa>BQH)=T0Lb6b7r>zalP{?BI#cqJdC@!qfYUce0HziIB0-w8YN~({X>4i%z^u^&IO}Kw0Qvoa2tb?w6jLZfIsouU5MU`bejEZQ"
    "2Z(H7X9)lR4}i`B&{DH3w*e98P7?2$0>Dq%;Pd+PH~>h0N2LE71AvME_02$`BXa=6`avn+Gz9<<^*U4tq`=_H8s<@a1sWRf@kT<-"
    ">OqYa8m=E$j*S4ILK7qx0ig9qD1tpH{iEjL2!OP}cGMgAJ$vY}5&(ew78)092V|xwS>g-c-KTan6<Ac*J)y%vtqqeE1oK3p&(XEG"
    "t$s@ckVgEJ1TZBxz}ZwaEH?yz6D<{3NsFq6>_0_HclE)fB`fWD`(oI-#6d9!P~`J;4&(qbCU|1`GJsYP#Db5DDgZcu#%H{UNgzM~"
    "aKmSTTN9+Vs*x!w0Q@`_0Hm8HztI=~WLZ!Cescg&P93!XfIBV$V9-4&002q@3;<9E9L9x$9&_WU6E$tyq=OjL80m(YLMB9?Fj8{>"
    "2>dt18dG-iss?f)2$G}#b~8Q!bkS4%l=hv>CslnXywBgQ!SY0o(w5agOohPqF0%rrrW=rHfNqq~aM0;U?$3gG&^^!~z;B8G*y9B+"
    "*dm5C8U!Q>=r;g>r8@&G96l=5GJyr#uGnUa{okx;2R4){K)wi&5&?7oaMq{_pg#hbNg2?D&l^h_YM4|7xH0$)aHGjrY5?H%?>7R#"
    "&!0yFz}JLubR+=$)d&EBp*R8v0O+d#aG3%?SrW{PAOQm3MGhcs&g%7KHsGAat7a7?Bee?fG!tB)&S0nH01f~E35j)5amyrmSPcLm"
    "09h%&-Lk__tmdz4a{5qkfiR80D{j7`)1Huy^{_wzoD%big)$zty7-1UPEYUF4m{uf$a)eT?yp=p_lyG>IHdhbDgc}|0)V9^r3bQv"
    "CI*;`77DYr6+q<Ju5&s&VAhy%RoUP?1pqi~&ZCLZpYi~-Ou&npGzT{klmP(#O8_Mz0FZ!9ss=z*N&o=UgODLy*2;qaG64MbRsi_>"
    "_W%Iax<~>70H_WK0KiuS0B8b2U!VX090BsG4%F`pooLWqH4<$XXGB?L3Qa8lAd%NiIsr3BJ_rC$`|o|BAtaO|<P-mVe$-NkSq4H0"
    "W=%8$Oa2e(TVTtx7HgwpD{EVBzG7?T0|3r5NN5uI{^4FG=C(#zBNykQx@O?x+JTXvWO1&f*3bQw=8$VI6Ey(X&2sPL2msKY&5;(t"
    "6)9E$tvPf8?C=27iV)!Db2^2HM0VXOe}bU=xvb~GWAj^j@;z6WE2zMo(~~OyKhpsKKA4#jfoPc{2sr8B8-xN_`kzf^1#<}SF9HCp"
    "@015XY``1<KpH?K2B;S(cOS7hCovTD5dt_pjS>SE>%*)fAWr}w;Q@8{PNt507yy_Cgsctg0pW{n!XR8!{6#OfoEO$88VdxVUKQ+H"
    "wsW>nE8H0XI4B&F$88~Y&Qe+5?!V=_gi1`n*^h16-qa4vD|YjcR03uei?4C&)z0#R9E;>`a8M5b>4~`l05A&%`4VJv?X@uK4Mwil"
    "!lU)AfS5uTV%pB~`imSsg7Y>e@wgZ+rbhs^pjXNPi1y(6W*{{KkmUhHJ5UJ#MuMs&006FUE=e1i0H8zHi?Rae$YLS{Xg~z|-vNLq"
    ";{i|+KzM%g5C2OY0;CF-D*{3b2(nT4TPOne3JNV3=QtOzR^`;I1puP-<33127AbrEStlY#qLWW)3xRPBML=#P7J4A`yw|D-Aitks"
    "Jwr@y{q>Idz%I>uTKr+_003`fGGJvBE1p=hY%Iq;?Yp|aHXM%XX0#kP7zAW$Gx?)*2q09YCQA+gBrc%VQs}s^2LLLa(eSKuBEsn-"
    "0Bb>_K#t>4I|oYmI5P#~spVK^ogPpSO``}Si$S+b$LGNPF>VVp9Q98T1-(vX6+qt%l;{D_G2y&Zvh(u`ts)R-0IyR3fG9FW07!%Y"
    "Y|M@*1rPwRESURm0RU_=d;*~AUq?8)#DS9p06KgGxa{XH=V~Z&VO*j<%OL>Wt|`s_+Es)A5&)i95e)1L8e)_01*igm*OzD6M0i51"
    "jkJU;Vuu<4F!Bg+XW3)HdBxEmgTZJth!z0MVa#j?%uGl(V=0llt*UXXL^rVBj+_fX@_eMPC`yuqK={v2oCc)(qvN*FzDh)(YX3j~"
    "{6*SlJpgcr)ZN0iJljq>doVxA#HnCi0{{WWHrf_XX?1O(h=6yG#z32@CR$--znIV0<?`wTK{R?GWM^7MAcRvl2`|B*As|a?URvH{"
    "=ar?Ij0y=x{}ur7rcw_u(E&nkT}S{WGC`OMCYgY0Qr{n$vyD&#n#DN;z}>>+B^#SZ)g+k|04S0t+?A1=Z0e~4fb@9@drK_pK`j8V"
    "8bqPTWsSv22(U)G8l492Dgc004dDMnc^pqPayJ{p)}}b1u{5c%Ba?uLJcb-i-OEG3ZexA~8zGrmaL-CCLnoKZs|A2gZpAygmF`M%"
    ")OrC$5KM5z;opilh(eyEW-ySD0H7&?$PIBrv}YSs;(6F@MwLf^d|O|R*ee5o8UXl^*8|Imf|URO6aX<K@iVn6P_pudS{3Br#2fJ~"
    "f4y|{d5ix=0EiPw@Kgy<elaLZgRAusNdNK}5S~xv;1qzyE*{MW|BuP{ksX}rH_7A(0BvuyUvvt}UWWkSPkJ5!fGP>LuR8*;S6XzY"
    "Ra09y2N<XgpdmA@bgN0gr1DRjt`pk=?S#S!E%Qais7yT5d9UffXh@(P9!MpQ0ni1v@vS{~Jn`<RFcFi2?<}`7*8za&cS&>fS^ya5"
    "#8O3#G`8*tHK)~7>yh_^FAoh=o6TN@B*=Cv!o->gKt%w`1!ncYlT_NH8UPxLf>HqRB^itSSx5j=(?V9Rl%rJH4l@D&M*sjPfUCjf"
    "K^w5;=Yv9GabgI9x<N5O7wuQw?%A0c@UFSVsoA;G_U8%!fU{Fa*0QMVbua=D0MNNTFCs?;0QfFC6fnZr89CsyB9dLpaX@S1M5zw^"
    "G0pJ+M2!7F>-UP)z$oe`g_GC0H62bc3DLy_anIGsVroVnCyl|!N`ieOFGn{pi>@O9;JMQfAB77Om{|m=-no!uXbJ#^O4h3Y097YN"
    "f+a&jtt4>Z%)~q~p(UP7Fy|8!1kGyz;Dh4w7iZa#ARP^m2Y}#h01()w@rlhcs~F2m`x6~_pmgK>TL1tx0AY3h53W92Zbl;<E1XDP"
    "Dr7$(1<}Ez9w>qjE#|E4zyor$1(gH<cErY9=KK2pY;pu3Igk@04*-8w0f0-*iKJo-Z7LE3b}iFO*0*gai+ngP1Hio?0MMKaB0ZQC"
    "+{Tf&TEY3Db}%VU$`P|Mo~!L>RbbBYTN9f{bqt0Wd5xBaF&zsKWZ6QN^{oI<aRexb0E^I`6AiGg2oNZRiOgihR7=nZM!oaGSP<0j"
    "B><>%0niSte7@<M001F?1Bx$H*`mtfASeJv!s3I?K>s5EfKNmO-kwoA8U*++tlT_Kega8Q6a#TgCIRW8HP{F#z!@?CK}`~ng}sn}"
    ")d+%UslZ}5s7wOpS9MJe0HGf;S;NtIN?~e1H#ZtP4vz%B%k6SH01)Z-#b&pm$%pX$D5CA34Qe-wMWJoX*AK_}g~1>))TgPdn?XuH"
    "hK$3&W>S*mD7_T`^b5Th0-yl6=Kks0!C;Hr>~eLA`9_;o4~D5Lv%KF42mJy7I=RU}Jx_U`Q{znlKs&)01FU_uYjIf!0iZkJc^-v~"
    "|CS`6&&nN9tj+~31psCoMzoJc<sg+y)0CT<%~#IayqfW%1SHs#NzF7d;mF;BBX17@z#KF?)&wmq>*^{1k${lPTBEEDQ7V^G(`ahI"
    "r*ViJd{+$sD$#D%2h|S3ClTxYu1!E@a>OkhZhr>=h*G~fnPY!a(v%z&+{^kvu^Z6*H2@fgxex%wQXUo%dbNYhtW6aF=p(woJyZ0("
    "X*B4m008Rp&5Z|DM}xf?01&bk+m>&V8G*^5VD%FJTbO_><yZiKJQy$!*at9bq&-Y7Ol|KmPg>-Bb`K(EMMc;j9{_;-PJS}T1VOX_"
    "fUNlA{;B$j+6X|ExrU*_ZLP4OIheYem%gY0fKAUrR@*b7_>a$so;*1;>*3pvf<D-L1AtQPpT)6S?F07izTH>#0{kif<h4NopEfHf"
    ")e52q>fEw?0H9xh{@BQ>M=bF#Qus6+SRD`!-v7G*KsGl)3<9RcUoj<^=7h)sVC20G02UemSiBJc7H<TA#ob$a0g_a}AoKTROmJU5"
    "*zZ-SVENPac00E)88~qX+Ow!>cI6)&A&10WH`l<m+t(@rF*lxm1$6*b5$t5J|6U0I{?xiFx3*zLdyZ{%7EJ))8&%tQ#}^+`9hv)W"
    "n<pQ>GXTuD>9P7pLGVzvDE%e?pfiRtGX+9{$OG2<zZes%4*>K}<w4))N<|MCAd35{`*RL3w=bW)3jkpL2WW~0O8`K#ltu*+H=y=Y"
    "Rsz7!pI<cq@b%}<0|1bCa^9`){`z?c0FqzL0l@2DKYsxLGVi}K9j*;_jVm!Vpxg?ih=PEcw%f3S(3CopLIS5YR#cdP+fF9zmGuJb"
    "pB7sFfEYX_nt=wV*;w&?3LH8BaPGAI?UVyBJ8D^QR0ROv?vs>uZfN$mk|Ote0|3tjNHP({sVDxl3IJS_=3QtgvZq1>zX<@~3ZVUG"
    "v7o343hGFU*9XTeh;Hl70Gt8vE2b!+e0;#0N!&Ac0`MZU>1;r4Ef393)bmG9?}RavgD?;f`js>`1T^3`0)U(WqyRuVFQ^s({$@qb"
    "bk7&h`};5e{QdK*a#)am`|mdb0Pc2=9UXiAl|lS1(1WS!H?(MO(4aB|fb!Rs1GWkd{4tLSL}hAQ*#n?y2HFioSD)Gqh%>%kdzwy}"
    "Njo5>gcD<=(-~|MMF3qlps#OkO?<v%9Uc#^<h8ZC+wTJa8Vr)A(^;CN6mcg%QvqN^ZTXa^$SjlS6&k&g52Nh{Oh3sKGb2In0~atF"
    "`@@5CQAH2+L*Xjjr?VBc-Gi>ty}0O+kWWVJ=?Rl8zut##FNZx?1)W|#M9|yCnHJuBl1)d<Z(#n1M?!||^)3|$43Y|{3jwqMkPPKv"
    "fBOrb`8RLRsT<b=06p)Of`z}8SNM4t03_rP%82KE&7OBW05BhzHh<F^VhS+xgZsVM4FCaV7bk(L5MVr-Aj^)3-vcdx%H`-)+38bw"
    "xu*G-=R^(w(F11CLJwg7l+BZMD*K4j(Yw$OpynF-m(l{P!n-TIORp9HzFMkAXbk`;F@I@$8;*Y`0Q^XTkKL@0gXb<~@v|Q}06<F~"
    "rUMp@UH<xdnX|gO9@6DOEQ(@y?cm^KbpFFkm{5)Ogh^%b0DV{{Ie$+zIqmCA4*fEUi8(hkyB~T44eGN#6kdfzDO@d1eY&RI-({6+"
    "2q1k~QXU7RLm_Bu0ViuBotg+hZpxVS@e}hvRCoNl9sqtaU_jCTCj)`{a6JI9<KuaMQ4DdX3=4Zx1OSJ}{9o+-=;$I1tgHSN792G6"
    "F!aMj7|<J5v`DVJsTlo%D~Kj~$_RSX0};S<0qty27f%$yp3~wv&y!qLk>fX@)a+qNd+lC6iyn9^^UXYU6o^LVLV<@I07zC#R?dD%"
    "Ennv@L;xO-2Y)Xf0F7TtZBc+#8qJb)8RnUQ)I^v_^Bc)OpQI%NJMbmEAgEs$E*Hhzrf(RN0q0x=%4|!c)M`)$tTEH*b-I}mn*?Ub"
    "@k$_;6k`uRHqW}}MN5%GTGyx|^Uw#6LZNR%@qi`RDp>Z|#2o9m2w<U321Pv2gF5n$y=nm<i}dMRKu76$cUl1Ws6OwfcwX_bw*Wxb"
    "bcUcmxT#o+#7`IV!$(#XoGR57u>)*uyYEB?|J<xFJR|qbtU5JCe_^xT?b80*?M^W5cH{<{fEFz(>zXrwlWJcqa=Rg&Hg?K7{-(6{"
    "<`($I$b$~*BAfTp1E3U3VwOEEkMXn@;%8QAkBl9wU~YL%A*!MN_+5?snVLisBkELKJ4_X9vZ(N8$GORhm@K0iDu#&@w#kQu<dg#t"
    "Nl!fV_!&O2Th$nnVTvERX4d0E?aasK0CK^%jN%LKs0D!Bt}V_1O7t&|5gGs}3?nW*Pk8;YNkHlVkHhRzg9wsELO!1aoUl<0i0(Se"
    "2@b6j`0)=IkB^kL*~kY5b+uT3IwAVaLaclGZ!#PSE}|nI(Ctp0h$B4Nr)pET`<*pRerQgELa-qQd=0LyjNJ64#YfN`uE31uAEOm7"
    "|3`y~jbFdg8lH4qJFp*R=9fQOG?`ABw^kg#goVt}yV8cpvdDS!{CD<$a*+V^$O)1M%&46ZW%|%(bmf~(KPVTbz4UErLk&D5oC+hD"
    "nBv%DjTtoLqf^~Xs^q%4D(gE`|Ab$AP4obe_xN0JFMUuC0C~?<pO>T*^#G8EoS(_7tK-Oz27oazF?Sup+=2rHG}<fx=Tk2V8f<Mf"
    "4Rh1FbdwK7ZgGFvrpXIUk-E?-b^Fn1D9s(_Z8RFX<Ei{+S_o8Y-=g|vOOp?y_v!|u6$ko-G~FqE#eS^gtqCtuZ2S)y-V`(e<g9q&"
    "OgDMX(eKo!vxy33fP{GL<>9UREmnVb@KB}&0A*8F9XWBwN&rwd^S_dkUQ!vT0RU}^F|7=|2>^;~$oC2tyxC=<%iiP;(kiJm|A0@>"
    "ulVd4zMsBO<qh}83`jxIl%dvRU6QNzEoSf4Kkl=gjQ<Tr9_{^us3ZR5@Bbr}0Kl8FoY0+)?#`xyRssNL{i>f=4FGh0kiSiHhmx20"
    "_+|iT?Vque_7eOTTMYovcu%%F_@=OINN)`Q5CpJ&O<&>lV*>!tJn!yf3ji$uwDunYfQ29fFXaEy2Mz*2&GTvjU{QR9MGF8e0JQd>"
    "jsU(UTXVw*AbH+jY2@&=833fudo4Y$1%MU+TKi`K;IF?+XZgRI<N*Hqsd?V(VE{;T4r&hIwFQ6{09yMG06<ok%T)oAtb8Q^-07<T"
    "NgA*c0CLrXtO}62d<y_A0JQdx0YILaqp9at06?A$m;pdq2&@8t{PS`=fUhk8v;Z)E@6x{Kd+n{O1b`BOuk?T(07?YD5~WZN0Qp~g"
    "Ei?i!<g@_rKL!9rx<NHbPV-y7LaOtdJu}bm1>q|4e)TOM^FEJ!hrfVrl0D+T9RLc1-o?jP=Je-y{uR9ds@L-K^3d^B+Y3<a7g&^@"
    "_t!5203p8b|8pD6TW<Fe&+&iltyQnbH@xq+002le=u}h9OL_7Y>=$Ozjun1wp$Pz80KVUlITJEnIy&;B;w?6xfv9qLlXuvN6?VMC"
    "7kd|2=-dwj|E&O^_&>$%ucE8(?k^2lx2hZPFWE)-HFqjF+zps?5q>Q|&g-uMfY0}$>HYgv0+t()LSNLBYM88VEN)^9`wg1aTvF2Y"
    "GfpixxJgG6bV5(}5}>iJQqPG(UXAGsh{cJAJ>8p=Yu78;TbO_@@oF6>KVV3<$_?Wv(D|`XB<WGw=fHEmRKo+)5!mv6qo(AUXtZ*V"
    ">tb*mzwsFK;`^haLJ8OUJrMwM%1MU+eRgys&$tsPaNHof@4=e@AX5P-_Vpjo1K{U<O`oSU1lIz9`0YFTE5+8LUjqR2N0BhP<uts}"
    "@vnG4S`9Hr3JY=+9afx3Jp!#DF4i!XWJn^vK^^-Tf5CC(rcz<}5$=DX6<`%pQ;S_(k2LElHOv`^SLKE{<yTaveM>I@z1$GJOK8^2"
    "nQWakNWY=%nKbYiqGxN-_GF2!DSIxPnK13g!jKfGqq<ERJOBW@hobi3;ieEMmJb{CkNAO`w1cHRgk-P6>~}-}f9he93P=6^5U)$K"
    "oT>F3^B<*@3?Mq5xWVxN@OPS?E2ruXC<46}6oE46s8s|~6o}GS{`(yw0JOqe>pP6itnUBKOYWI&@a6zJo;ozK#}-1Jjdmn|6uId9"
    "`h>1=44!nT=M0*rW3Nuyiu&Mf+tQoRym9>8YW2gRiPfi!^x@SwpU=%X8-I(3=fhRu?+xW|2+Mp{e1B{+5MB;y41G*x$=N`TYJrA}"
    "QEr}$9Fp?7`&wsrcTh$gHrk(O4^_h6b*S<3G8?X%O+d_dSSJc7+<UznIKle?Km=H_sA~)#Y96nqkeJ(I+EHvX4xq6lnn2OOu3Y)m"
    "0Fdx-3&py_0Pt0#3HW+g6jZATn1Io*0l-vhWGosq0DGa`?OM^>P5~~>>#}*B{y`djB-3#4P>p!rVr{G2FBn_v@|Pwx#8<=*tN>Tg"
    "!O<A{gmWJkdRuawPbO2K9rv@zuNFU`p{X@?WIJ$(+0Dt&wn1vDd^3bx?4np;K>~q%UD(}SVc^e!W?h<oBxH$xOuXZ?j2@q%?%pJ7"
    "@TaT$Dq}&>)w=-zkC)xdF|d5P+99TKpx*R?(QEj3V@9iJI>7|k#~Q5rr&NKz{?n?!IW?I@0su+gr%oZoz^v)%+wKOmV0iq*9keGG"
    "gad$p_>e?RWE(=(4zhQ4Y(w1*^Bf5S9Q|VRLu;ALf2=ZS!U0HB0HDDjB<%B)nNHs4sU$;4DycsnYV64I;6tN-XmZ=&^2*5}K;ZJg"
    "vxN;IAZTOIyv%fTHc!uF6%CVc-l<QJ1`rgOLgNU!D;o=Ew7_lZXQbW=X*at;@c?mo#XJF$T-$!st3$ct>Nf)ci;5r8Y$+0)iKpi7"
    "Wk%vnG=>WDG`No#Yy-6!fcmT&>;4z#0+cMB31f{CZ>UPe!X3{qdI$l$H>6|67X78QWt??*Ds0bOf1TTIZMK=^?rw#o?d{Tz<u?EU"
    "K!EmLc#*lR7z8Co!$1@A#<rmctttYM_E@d7Un*a?&7Y0EiSey!F|!>70MI4sH<;X5K!Cud>uQvAfs1D3rO-9^XlMZ^;*mq=7aFHD"
    "j2op5-B<`CKEE_c9n!U~0sttAF7y-MqmiOJ<x|lk)vrMYbm-{csYi0O&o9{g@$b{@Y0tOtYDa+pgp78NK>eLnGfMY=9{_?;DwJ!B"
    "!~JUN3@gV+7$n7Jyd_UFrAT9KvM6xpT#N`e)@!3qrjGpo=H@!lw6-DXD$(Hc?TsD*L<FF<YYGg$d|8_3BnrPYssZ4McY7@W6!c30"
    "0NZcx1_0yX)ny~=Dvsu|qQ7}^ddN=fKP;;z(c{vP=k3OZQXb3(4A_>_0P9J&O{lj&KOPc@J`4c!iKox(*!C3ryf29g&;;^{dH`WR"
    "=%_iirInS!N5W_sAb^QYfB*9RPZp-7X*2uXmINj#Y^hPS``-ruKRp4^JQ!Nr5aXZehdYY^fb`ejkOdgh_HT=^0OwGD<_Xa!r*>WL"
    "5gCWf|4Gz7R-GFWfo65mXt3L*b`m6MLoZF7VMq|Z4gmHqbll(5L7)Ht*yHjm{9OT{X#jvcfD!vS09bcU4+DVtNA0*@PXDvwIEnZ2"
    "WOX{EHBkqDd`<!+^B@9bM}SOqIZ<J+0)X+zK)7hSM1}C6{fA6426_ji5;k@?vZNonI<O)2`RA7{4VXw}==mnY`~TG3(SI2LxVeEa"
    "R2-wzaD_^zKNX{$jt>FEpRvTa3YrLemLR}-ZCB5#a1F)bivU0&fo^{a3L(JFEj<5*$3lHFI_Cz`i98&p5&-s3Gh_B+^C-lNRSdx9"
    "G5>u4z}n2U1KYEIy4h9ZYr8mY002fU0FWvo4St*kkbCB|;vEaA9|C*q7&O5#iI5Ja0VoN`<4?rsm2c^nJQo#7R<9~iwYE(ZVo}F6"
    "pb`9`V~tQrGLsE#ZEA{~C^_<decJC!0bMd&W>%BA{ND$FVCbl#*|AIGsVYDb3-tVg20EPgoa5wWX<Po9F4E3LHY5I|_tmN-odpGd"
    "cOpCI+c!(i>crp5e(Cx%Z~IFU&Boe+dN#a&x%^xQ0JM$8lcBYk&3<fw0?*G+$_b!w$n_>y?+E~Xc5&h7>8Ms3*(PWJ{Y(Cb9?Yg-"
    "F#y=j0AOC>o&oWgrVC2{qn0Npg^Jvec>n=c@qG89T%p;awUGb-50~5sC}1)GO`6gIfG?((qpE=v669Rn-UVcUG1J1DbC_Zwn?!Z&"
    "sa}toPbXCgp8XDGL1KsfO93D^6?P30#%ef2sZ_g6u+qegraH~=sy_pqK1+_N=NJTw5I~IjvcFbPKS-(gW~sV66yEcj`>ifQ4P4_U"
    "Ir3Aokmm%01&E0U#`4QDc|}Zz8R-E48Dgkgg2yu)TC>@`zyLXnun3K-iT&-p007$TI03-H2bZ002X5Xu#q<XJr<-`N{0hI&H*)~+"
    "hjsER0N}GsYDl`snEWQz#Jblp7y_(uP`m$Ix$FsIq<GZ?0O0GV*aK)B!^4c<o&W$H0V$+3=N;y?W9S2FNCC|X>z$hvrXVT+c?%GD"
    "hcZYBs!{;R?9XCShiAZ7XyE?O0{~KHY6;nP!qs$B6#(#LH!;2S?6?pBsrmI+J6oeP3SOK6C<IvOvoNJ}9`^eJ0MK}6%^wq~!dtEu"
    "nl@@%^!i?e1BH?uSdM~Gbp$XCJr=vgkYHqskrLpHKzW4GYP!CExPLDIz{J)*hNfP2DMNbMg~t!*Kgmc{1_1m>0{~_t06^76cd5yV"
    "u>+$%P8{Nh{r?VdO?3k*FNSsdzm+ea;2N1z??4V90Ra4oK6yQjem&`atBL?zT0XQ)@YXQ0*$N!7fH2<A_COE?m7NDa+eHo$##f;Z"
    "_$&uW2}^>3WZ=|nPMY&p)liZDaR7j`<N+X_nES1%bx4{YCWka$oFB&%!*yJLHBPd*z;yr4<adj&mM-U*3+08&8etItZkJ{537&|V"
    "Z`b7hm~a_~W9}aCXnM}=&CN}ApiluI%m4t}y!CPJ@GJ>;6@tFt%(-6tqDgWS58&ax#*R4xObr5n)6+g}^nd}{>q`J2j{xro07Pb@"
    "p(yJiIMUPD6!CwD?vscMYw`x6SuCH{r`5A0AaJt-0O%s^a8DobWF~R|ng~FwQgGG1Fd8H8hfs-jB8(6e;{bd&;#!uS^I{*Z8yHwH"
    "<I-PhG-Hb0Uwnr%z$5Xs2Ks}}|2zN$j+Y~f4YA!-o#KcDlmfs}X+S`SjTLpm<^K+FpAG>W0i2w0YRV0DB>=0C%+~+_v4cu?4$OG-"
    "7Bwu|8bZ-?gr*P+2}L|w0{|k>#{#xqA9p<B#^v7l6($DQb0YkeuM9rg4E)viAOi7##>@U`;_(RpoOU~>bk#6UO9Taj_XdEF>T(!H"
    "Iz@dwGUb`j5X^y+U*+#n7GXanMU&^6Gyp582cisk|A3Eq(xJc1n}Q4rGynjU#UbCBMx^yl?O-9sjMETtq^vN|a7=TN=7P(rek!zX"
    "famwZx0EKn5S4nf>2~p!dDtun))-L#C-DT#@ZWg^@FO(^@YM!wg4nJVHGpvn0O!4~eFPZ@2yXpBDZtJd6#!{50{{RB3<n(mkFLL^"
    "7ytkON=E>y1ZduD=%Z&2oqMu<7gG#f+q}hr!AwsTH$^7kjB9^f7`72MzHDdaM1DprTMYjI(N0rq#`cLmfkDZVmV&ncK&O)cK%W8N"
    "68})(Kj3(Pvx9E}fF2!_{ZjukO<|{@XAX_b%|<I?zMw1)Rb^>08gM43zJ3=oANL}MQb`FGGgJ})7!Uwp4C9OffPr`n3`DQk6pX{*"
    "9UVoiDY!{IB4%WqQxYI1evmUouhXK4RFrq7xb2xSeUOl$a6?YIFHifYK7YF*{^BEsT?hZtBw&t3j(#yBbXKrAu+F-@Y!v%3Q~;#&"
    "Y)VssM1Ud!aR53ObOPvzuhA8tc`?^)0swGozd{f|Bz6G-JP8_41Ou2x!`|GM0f07{naL}La)5NM#U6n^l4KMJ7A0u1S|&ZE3!O?k"
    "Ip&-s0D$&;27nU@0B8V!=Xb<E3;=^d6`&aaoY8sSFKB;Y))EnbHoJ{8Mx;jT!8CKd1yumxM#EWB0DQviW@He##EvA2txp8{w&+ik"
    "06>o4!E8|m0{Iwn0Hvm2pL58l0>INf52-*aHoHB<kdAAwOfVM2+qH8U;b3SA_ZI*lFM$Mr?-YE1kOm~!Bkeg|`M;wK`1h--)^#)h"
    "{QUg@;Du&xa^`{)CNDGnncO^A0HEgv{t@-9IjCx){09`cI6tE}0AJBT;AEkz1AyS3Qh@3J0A5{JkpOihfcwM$m-L$y04!x0umAua"
    "rWXz@I?^HpVkD%kVMxQkJlXcItrdCcaJqttp5UVZpieHIm;`{6JOG?hfnad?J^+ALMv&-C;?mi(ffL*8`9>1^r<oyb8DO+>t}_4M"
    "bmWdIzSDLcA=e<st;$L3^sY9X0uTWJJt~@mb7dx9tyQhjNdlJQdGD;(#d}wluUSA1Zcq^Kj`n*-RsjGnGfF>h1~?4tAFpc087ctq"
    "k$Z2C0f4`M=6<6&0Q`J?V+3$_EC2+~ItKu+H2@F{&pu=ZK5+9801?0(%L;Kn?f++If(S^(z;pUS2LL$7mwbI`I3-Z1Vgn@|B&4K4"
    "?tjA-1Aq#V2bMSbBLEhL16DhQum<R&Pjn8L%_)&s(;hYDR@}19#T?s{V|rIh0MH$DiU5F}tMhgM$e-?3Q-cOB&nAcihLf>$vyROE"
    "iOxbC(DVpPCx@5B|7VoVIqAp;kOt7P$*E`H$30J6X8_<V;Ou$R5jc=hf_9tyipUkK$yUQ2r=sJP8mTy8KHrca03v`c9ij$LyB84w"
    "&^L5s5mk%odB!RLydE6^C_TH!0KngO>hqcdfHFg%ApqdiInO~oQM$0~2YM!O?>vV9c4IDpPf5TY0RRe!9nJ)tofE0}17!j_YYhNs"
    "DE;tU$M{lW`NFTO>ePPhaw{<h{rEj<CBUo16h~+P0I4Cgq9CdT4mcd#K2cNf2Km6s7?Ga1&B}mk`fqz=5)h}55&(4Q+r9*V%jBmN"
    "0c1z8g8-0r1DPcN7|!TDg8SopQE1N7^q+Y+0Pti7kl67lb1~@llLwyl+5iyZz{R>xiT{1t`k!Z_8u%?`1^?LOlL&=kHBf2gGLr=D"
    "q3RK~fK(X*P|_csKYMu+0D!kkSoI{sm1+b~0f4>p7yx+9MhF}O0P5(0V*o&%A<_^4f}xe`7q@ZteWoO!{^^Da04M~Engf7kF#ueU"
    "|DSLT;DW*dJ^>&HPyzrzMv2i6B9N0~1|<McB~TKOk^r3lhRX#@Gja@ae3zRAbO7+3_I`V}r+*{@peyL*WjC{`vP5{J<<6G-jO709"
    "m?MB80HDMF&j4`B*}zK$08YAsAL!+%z*+!cr{}_pFq4A30svfXiH9>;VJ}FX>@G_Le!ZJp<BFP)l@$OGVzWo>_J1l|3QyPEp<FFa"
    "0>Jg@fS!AJThIh36sz&B!r|FP2>?n^l_9{MJ%5k@0CIx;w0cPhP}L5Q0|3Zz9RUDYJWg)i8~~KrLnJZO7ywlNKLP;qdJ&Ly*+C6X"
    "pTixg{(l@DFmOGh0iX$x4q_Dd<A3L8=Ufpms0!efNdR9!;wMuIcgW!>56Pb|E1C(A;6N+U=j$YV2t)t?->x_UP}9g@GMsT1Kq3I|"
    "9>@n86_u^J*0!Sophp0JkRM*&IS~MGS_XhYGXOa0KtGIR!BTM$KIKgd5dc*%(cggMKYnhXovE?*0_sc1th-uP*d!|eAOUbn$A5)z"
    "U(pnRV?%biI0=9<0I~;N<r)GPhPhKY2atI)9UTCaBy9)*HhZzp&rTTtz&`3yN?@kam(ju$_=f?2M)EWU0L72t*Np)n=f`-wDFEc3"
    "*9-u1jX(lHXHZR;Oe>T&lq4X>0B3gSH9i9{5iscmJV!(Dg{TM;7r0yoq#{nL-gA@b0a#}C&`t7lLkmRsbjvRaVJISIF#$nrRs#SE"
    "AVbo&!66`WvJ^L#$b9n80RY&)0D!(c4RpBwmjM7Z0s??RgEAnUtje}7h~!Qw|G&9{R12rsDUp}?8ZoGckrwzytI1610HSU6`=5WR"
    "g!>9@06b4UG09U7lYlb+FIHO-K`tr)z`0YifR4iMP7pxg6nlOG07wCxX8a{00z8`fQ*QwP;BaLC_*)s!lL3J0|5QRK1AzLxR1qle"
    "#{dKg0LpJtW*`B8wAxU3UNZnFN=c#7Vz;xa&qGvu$>#x^>P8ZmQxJie0`Ng{06P3V(oC+lawsj~16||(hOG2wn|z3;ufbjYq>TUw"
    "LelfX&5dD&5tjlCrv?Bhea+lfIDAYGJ!d^G`Y7>T0l-KA;G|EvzpnJ;OX2zaFCDe}-F|~Ip#AmkAOMVmsT10UXsE>wdUAT26#&p0"
    "=0kqf*LMyZTP21b<aX4gqe2&0Be^?MLICCfOA=5T7Fg4AJeV&`BHzaV;Hb&Lg{3Jy1W7Xxd4692KxfxQ)sdS7MfbuZ@t_Y;fu%>L"
    "IlXLX_fKU?CwuE({CnExWr+cL-e0e|=b>tFSA5>9i~!Q#yvvOt73lC<{Cmv+fLrv`0KlHnI`^y9LwgswL%_M&uo6IZoIfNLm;vB|"
    "g#qY+6RVWI6?ZNSSf3jVzMC}L7eVk7ts7j;Lpz@nleBQC4FGbw05{+ZBCB{yrNB_s5-R`z73?7rAr!%)e3;RLUw-^{0Ps@)0OgMW"
    ";8OB`2MPdm<U@xd0FZvPR@x$oM@JF%o#6jx`M<lG>WY#8WarB5sM#SvS3Yo+Lx5lc<N^Q^1SoR|@DWP@z|8<^8E~%2O2dIS831(m"
    "DFBFqB~Ax_?uqp2Ou{Bd041fjP=|!4gSr>&k$>eJKj*8j3w6YI;dwtRpZE9ONA1t#Pm6HV3;>W@UE~7*Yx8JU^FE23*Ucfohx3L#"
    "LEH{3LjW!Y%4T4(;jC?qQk`pxX#cZv1Tdiw2p<-O{Lj?jPXZtMJ`PGFCM5$Z6^8QUZ;2Fu9sqC#_&DL9k!qo6F-ev+*rNX+0D$b<"
    "p<KVXMnWP$9tAo{8Q>~Cn`^rPPfR@kI71yxGhG5k$4KIac{SAwD@Wb%^#H(8Q~AyidtjT?{2w-gAFe>cRu^g^9$XiX01N=mJojLz"
    "IdKTB5+*7n06;WA90v&SNgBwE$I;3kHwFOq<7BjV-o7qgmGipT<yBX`TfFL@Cw}~z?()iu5a4|MI6u>wA%6Te04T!h96kUFj9G&K"
    "Vet^qn>M2ZWsCGg0>F88QeBjH3gNzJ-ML<-?K=qMk<-6jUSD6!B;XCcx`D)(HUt<2l1g|@9YbTsq-R|(kqTsB&;tOqvrp%=W|$9|"
    "wz@z614jS_0O06E{pB)%O!^^QVgNXiK|w#=p!wR`C#4gB){J3=bJ^x1t^5mjs#bqzx5{J^QUFjDl<;*)JtgH2Xa3&jkEjFy+F0CE"
    "7|PPunFrvwg<e)o)gj>mDFE;tfd|e2FPkn?foD$GKowZsbK(Dg>x~ega9&rwyQ80K?JtS}{z@|j>hn1BIImEAJo~6T?>GP;nYBU+"
    "kotfYH6Z{B>v;sYI6u((nOCkAhX5h~o}Yc_q?synq}#s@jj)$a><@u}cB{f^Qyd=f3+^Zqa-uf|(cNxq0U)xsA{_u1gWC0;AKq15"
    "()R~|Qvm>^1wh>Z9VrWfjERT<D0jkCz{sr;1nDgF0AN-CfDIPUf_>lY*y2Q8+0y4z%Ls|2f6uCbC!)h9D+BByxkZ=I*9DTZGz6eR"
    ";Hi2hs1P9><reGOb3sZ007Pp=%)-*Jv@@|X0)Ri|5rC@?vss7ZfPIacxefq6{&lyw`&ni9*<bmCeY&r6eDJsaX@new=cW7l*S|i_"
    "J5@@rJ^cE|Hv&MO1+;MHk6X)GuWROh_{BuvMb~MT1`upcgX_{<0Kgdl?|xm;Y)0r*r|p{qfQmN^-WinvaqLGnK_&#QEjLO4z{__7"
    "CIB#utVH5=vLaR47s?XPDpW3r2k_%QM*~VF?v88+<|+US04WOKef1mF003zOU}^wh-53D4$OfLKJT;twFj!6hk+lP!obqF@Bmp}+"
    "@Fl3bPO7Tyb~H%A(8W#O)Jl1OVE%3t|KC)WmLogISse=iu(L$x!Y)aIp|vsPD(<(SoIU-?0I+=#tpKMdBJne;RHf4bKr+NvZ?8(~"
    "zd+E<%?B+ZK>m=Sj2`${<Nsi7Yu;Z&05EfDVhiWG+0g#FuA9x|yLkk-_+Yrr5P+8HA75D%7!YtyvcMfvtTf$L<Hpvq5dxqg*a>Si"
    "#fbnAB*bD;6$@>lESy&aN&#RqTupwwJd2i=DSDD;w6ZIg2%b3DFuV0Wodt6Lwsv3?yZV=nt>04t;E(y60YLEV%(MVF@A1D@-6{}M"
    "&*s_gN{#)SU7vPT`H1NH(a#}RWr;vV7m)owT2<W2T)qm2#@-nLfU<<wrJ}Sd2lTYx5deID*)j=mBNEWvCoq?Q4V7ciDgdC`k8}0-"
    "pG5#@_`JXVE<l1&r}jR7D*#M$$HcX5Zy)DSSX|eu{!<Ka(NhiqJ*V0Dh#(-UDaHbH1PGj&LUz`v3gDXo06F-mI)F2mW<VmB;>92#"
    "CbNM>O~4!gh`5nM08AQ0kDwXXWk&7AdXY1=CE%ELV5d81>i>g`3(OI~q9FiSL%m+xoq1*z>V-8+h#GcT3se-+_f%NNEj>{HU^1<q"
    "^hv1sps*&>1fW@^Cgv*Q)tsQTKqAXW04!-+NL5@t?$aa56VfN!{eE{!|A^kDPEsM5HDdxcK!DtNT%G@S=y^Y1O8}re(yR7=^NkUJ"
    "pTDF`0@~Qr9JH>V{f8TmUhEtpun_{#3{p-vtx1AOW_9OQ)e$1l(S9{n+YN}h#{rEB4rM-&4*rJ$0G&XRI|3*3Ne*OMGqf7hyfm$V"
    "!^DnJ1d1A}f|LLEhDrLB0bu<L0D!HaL>ZVL91orWfCvHD()K%C#+q5*N*W+P5}@)4v6agK#0IwmTdJUCF_lzME8Ih)VF#`vltFfs"
    "3`BpBe7Aq@w^b$2DgYq<k3N}~r~hzXu*vgO|0h1+&%#Tc9p(RxB7kYW6A(2(>V-od$gbD=z#x`H8&JdmJ+oOJ0KMlZ<L9WG;F?t?"
    "U|q9O2!K|A+BZA$`LrWmYq^ZPDgfA|05G+f(@w$w6dKY(u5*NGNew`mCw$Cw;88H`H9-KH5!!RJfR}nYe+2;CBGtZ`8hBD+OR@l`"
    "85@W$V{qU=Sje5?+%%}p##0hm;R8!OfHQNhG_tuxk`vW)<(M}y?SU1*glq}gyzmtlE}ovNX9H9Mz{iRatc6?wDtvd1p7&aMUg4z-"
    "z3KhG5de(L{0V@>fcc=ccBY5s^*LusBH*Hn)#x_j9s>dt*ukjl*sBh$k*vFJ5C9z9s>r=>B><R#A9xY~Of3NXn5O!G&yTMS=G<U2"
    "lkz{Q8W0T<mMoFQ$x)-hhZb0VgSxqZeQ1PV^~_<;SJuVBAScHFz_?fss?Pyx0O0%gml=u^N_Wr!0N`nYDgr<kXi&TH1hK;UGX(&2"
    "6m|f#j>-{AI_Fh3b;$ap{D!^|Ki+LBNUhZX@c-Km1At#>vF0`a`H(p}d|EZmFH}x2D0|~Z5TN{7bZ^$39l(rj5CTvQpfLb|5Ci})"
    "6B>~g0Csdpm`MOwG#GPZZ%T@QyWQ?>(}DdUwhbNzp6vDc#9zOEc?CIqJC1T!4%P6x&PgKx&<zOpgONEeP=*f+KIH*`6oGbXgWUlD"
    "!2UeQ0l>qozP((?f+YzGsR(3dbmzNb{Q$p{2(t}7{-_xI__X~28t})tZ8v8E{%-(4p%G|pf$}nwyeg}~Rt|lzG!=*gL1fv%_(=Nk"
    "qF!0pCrzLOL;#}pHkn5oF0T^>Q7<rR0f5?A#i$z|1bWyFt|~-<Ws3XA@!&3a&ZY@6@RjuV6bmpE<O<z+(Qq0^ZZ2>NTy^Ne(E#9u"
    "LucaJg#aKN9|Zv4b0h!+Qp1B=ft~LFI-oPn%JOM~Vkk5L)jF143<WXsMx<e!iB&QAm7BjH`Xq$o|6LKlG)Jza8sH|$%&mtF7Al5>"
    "d=LsDz4J4)*rTe}1Ob8^0C)$aM3)6J&`mxj0LRa8gGQw1rPKroN3{{apM35oCcrb1e-57j;0EtG9F&B|qIfD&37(BJURPuV2HhSc"
    "`(rFr$ep^y^RfL^5nVqL09H7|paneF7qYMqPk=7~K%NGO2%yPGVWj|gXbNd63bKX_pyPl~N|Qm-Z1P<h0BGD%K&D6+rSCG$Rag;K"
    "G`!==fd2ykkZ%OCU1yV?0Fat*(CAO<`!W##c|aPu0ltk_S306fpejSWrh6`Rd#m!yc?7sw<}?9G<il;$jDY+)<OROa9HCLL)B(U$"
    "J@@l?v>KU+yc;~cD*(VVT%Wq2P)eXFy^h`Oi&0=v7`U#hO_15e>A;P104{3sqzW{!<bqg0{215i@Ks%jksB3L)DIp3NQ@v!126%|"
    "JG^4&5LyEa4ly7EL#jy?7=pl5TUy-d_~gnuk_07^yLu7v%Cj8xbX9wk|91f(P-4C{=7E@KiB1j$i$;pSZa4x0z&ch;{*Sb}9f#G~"
    "z-WYMZ0slrXHbAf<7o}?m?nHE2!JEJYupt4-)$;P4n_bS7e>)-EdX%wKX8m6Pz7H#af5dU04df@dfjk%^y+nqAxs%^zb2|$=aT>p"
    "0RS&g>3EXnj`>w=d&IKp<KGVeQ0)|l03rZ1z*<OH^8_E71Tv-Zpj~jlF(-UX<H60Etfe;*Vz=b|kDJY&X+eo#_@?%-LrjwSf1w>5"
    "+o4o`K>o)Bg$=HRndVr+W(hslI`5u$%s{v)PvUZ8eNGMsda#Vwe=OEH?h(!Ht4142HX?Rc=7TE$aE$-cn#O3*P$3vq0Du^7iJ9{_"
    "7&cgwzX<^Hhb<rg0f1kBtXkygqNk0RfYhBY<hV%}%(01<#n98}lfS<F5&+O&7l#1+?It~CKAOL=ynIn2f-VFNv&M#lc|k)b3~Jig"
    "xgLn2?;A+Gn&|F82jGHc20YVOb=@q~#)_QGf1O!}JUCTZBPTRpXPZ5x02XPtbueyJ)kDGxw;>7C(XF?%Dw+v{a-}KJcdS_|g3NoX"
    "Xo95xaD(%|6CN>}APVV>h}?y!E>;2nk43>apjD$b$KMVBd|2+12xv{DBnVa}>cTzQCtA@B{M8!eUfCI>QTP@zo=$T_1(9s_^7Kmp"
    "AO*q>Cjis;>-%mRxxj)HB*#G=Q;VuPaQ~TUVGt<Y=ogxUNK=Deo)1hj_QUwU(W1jSK&ho<Pxv}eSLDV@*j8pU0N|W81Us%X<sA~;"
    ")dPTQS1rl9LcU9FJP8CW(aV>N3&Qq~oWn8m30>b4>sA{9a1xM6Ayspc{&N7p2+%ib@-l&|h`Zk1N&P>a<p_QrCF0dQ+%!01)&q%x"
    "KC?ZQZQlq0NUw(`gB>$vDovE=^C8*@z}rwe2UMY>z@zEcG`$dGL&fNz1ApCj|10e<e4Bqz>eRB3AWdfCZRavWw|1M~hrqm6bULB7"
    "YXrvtz};879)U5{i?n?S0|)@@CH;$71Bt4Uf4nncw_M(^qDT<{W`Yy4nKwC({-XdOVt~3XZ78KJs(fC#*6VdHK4UswN?6!#oMYxa"
    "%3*5M6|A#n0DubQY}X(G_)A7rU3UMFa{Wl~K5}^nD~m@yZf8f`@c$9Ro-rrdzhkmIx}21}kxbo%8yqqCJCW|B(Yv=d6&k&PQxTN@"
    "u{f~ff@{y}{&@8p8-oFE>7;>lVDzR{!w~?ag>ix~^OJ#448x4<ImX0|j{|_+!?*XD4qT4_b$J~R(=k2F%4P{gJ_CyX;#<+4#L1Qw"
    "DrJRhJztRQ+$+mWnTKot`5<!fDon6#Hi?PJKFz=ceEpf>to+}()`4>~i`?H&Vm;~d82K2}$j9SG-T!YGW<r?`i9XK+g75b{+i`;="
    "JyiP5Bd!RMv~hN@J~0rOR@G=|*IKFB6q55~GtEP2<AXtr6aq<v;p9et1ht<iaNqjT9Xc!HEqFnGoZ!T=C&Ol`znrk@=AEVkA4<5o"
    "_34;t)pSBP`C<z9FWelpYatGfypU7*MBN{23ZwAH;qUgpz#Ya}g&KH}r5t$VWAN|uf1a0(72~cP$^dS*#9bxqUJWhNbw)?r5;XY*"
    "ly!)0>yza<)#?CI)e1fQ$FOWM0U85-ajO6rP7sa#x8Jl#F4dBTd>pQVqc<ZTS;b@%)Y-{9ZDT=vD8&(Kjj1p~U)3+uG`v-2M@Ll2"
    "6V*Ql@&enc`TF_&{s%6QuSNtp;Q-GY|2xg~usX)m7}X!?i72v8gD4&!cT2z|N7BJVEd~|ZFz}9Eq0MAPT~Y`p_l<*a?EcCJ_p1J`"
    "`=+G;<{mad%dW7Kce`K5&<Mt5g#3MO=4<Sjt>~XN&mXszCD~R{($5~!3DJ9VXzlr4!<F*Zzu<D(@jX`T`ywee!Klhk+BMeN|8opT"
    "t%b(7({;QGYXP9O*8auT0zhl6wE)msYpt~a&{}J)wE)msYvccCNv!r7v;ffBzt!9@`maF%*KGlywbtI%r=Zsz{Raq9-Z7*D>G*yW"
    "`7HocUL&u@+_uVF>L_fl0$l}6T`-}^>XRDPKX^&Np^F<+Zv)xm9GPYq2>y-Vq-C_i{CDg-b^RJUQWVr{XeFMXPo&(mADpQDWh>6k"
    "8vCnke21@0@=*S(KJdT9e*^0U%dgo$i<B+hkU{4E_W%o~e30%O)KzUO4&h``^!6lze{7p3I@BhI<x5An>`-;FNN4~fJ|I6zw~fT0"
    "{5mgk$90Mc8tF2v^O52~9H|eKo;Fq|14%-BX2;2bS2GF=R`~2*$elUVm1WzCG!&7M)34DI=NCn}*m!t~Z0%u&bTA_0=D;xf^6+9p"
    "00PIVn=0n}{{M?k7~Hd%F4jQ=AgXNIFBOGNxN<m9NB<xMh;=LI-x<-i8RHi8eA4vc(ePLwF0P0byah(^nFBv;{)T;_sK4FJ4)y|J"
    "xEE=3StJ1DL(^A`1E-m`6;E}g7r9oAIi>9oJ%<`Ui}|<Jhuq>N99d3{9W@vPB8WYsk>x)-#w}oA@8-v*-e!6EE650lh9!)HMbo_e"
    "8f!Nqy)Bd5WPN9~Lg%E@pg|n>iLMy_Q{AmW{U`4KgI?H`(Yw0pcKc9Tt3Ud#!Wg0fa=rl6^UyHn9*k8Tp4{O7Qy+$Rv?-cf<j#Y?"
    ">=8Nra7Pwme|s^XFV=t922=o`xw=@}$96{}-U+7=uf-y4_QWYR)hV`ClB0Rp&79gR1>HDm7>2U{mn8$h?KSle0}#xLkpMp4i*Tb("
    "x6(R2qo6~LHb&d-mEG^W)9sum-}HLLS;m-NVC9B^7VVhXfPveC)@2jx=Eh)nQ1;%^Jd)=hHHNF5*WMtxZ0cCvew?hJYd~M`ppWCr"
    "v9UBI7R}yG=L7_<V;K@T9P}=RnjHvh#2LnKIcB=vJ33S_r0FXdxiIM0jlyQl5Fr~R2Mhs1?Sl>Dj@j#+8P+)b)trkTG*h@SsK0%U"
    "wrVKJ!>GSHo;2ynhI2`o9!Sa>iBczPPkBMm?0oD8AxT#oSA9EP9L^-VtHAe66OwEmW<!w{<pCWU8V&%JF^uV6ngRfp^aLCQZmzX*"
    "qL}=Xcu}v$&d<+sNQZ0D)4JLPe)&Ruz{>3zh(xSE>STCMjtT%Ua}j?J|GT&l|5g|V<7V%kc5)~ZBw8F*2Kl{*T);(6Pq$#ZnELef"
    "{XNTb!Eq%3ga80bPToAE6i*9rnHVWWVi3DqPBve4d)72M8Um<HHGQ{CM39bQ?$@n84?XB}^8Wp^G{yjXQWpex5G?*cE2gKp07ri2"
    "q1#B2hIN_t8yjNw=<0{U(r|2YgZjLBbM-0Rg8)Ek$1W5Afcm7jiig9xEuW4YIP6j6F>*}v3TWE5!^6>o7fsyB0P<5a8)8t9qr-};"
    "RJ*38J!s;Z%P$ZpL5yp%TrUgx_%z{DtK@>fqH~cr`G-p5xiTt#_z_Jx(74)%GyGrf`&=}PcQXI_egJUB1J^DD;#^!*y?u<uQ$D=M"
    "BQ^$NAV9U9_Jx1vhMGKl6A!MGuOV`B$4(!)6#$^={v}9G?G_+lm_^N2Xb@iYX|U<h5J2Lv2zuTte-I42a@<nau08_Lxk^X}XJV(o"
    "fJe-WsNU#kU{0?`E9U$RDr9f&t;HpdovwXYENwOUfw#DSe%UQZrkRv|W)47sB9?7+HikxC2g-P`bvh>qTFVH0a5$_Ib(2SIoHZh("
    "3`_{t((IZ+*9z8mc6~|@D#CMfVm^F(*vumd0M$tVG25F&K_N3n7Z&F=H#8`3Ln#5IEI9j60$^owapEtq;$s+Sr~m*0jq^IdP@tn1"
    "7MynRjsU<D7cb5`aAauvpI=l0fEocn=knoUc5-^iPB!rGsRjV7*yG~>-429Ro*2Wo#-B)z0PCD4Db9R3Nr!2uOkfuBtv67LHQn5C"
    "38PPW#)*J{V-5m94k)Ad-wgo}0i*y>>C0X`oNZs8i^9i{jeVR|k1+~{$ujC;Xs$hdE5F7MrZz>@%>aNV9c&jgsDYIIX2S_hw!(Dl"
    "Dz!y_ij0pv3_~6VUYH6wC7rg-t_lE%GeEgz&Z5w?%1e%>`o<6w>g?K?Lf#PaS+j}FvFLD0n(+74l8i3T@(4Uq2FGpk#<ov6CInU?"
    "$--lG0p5^uD&Dpd0GwU0X#l`efLntbTBCV1?r#GCL;&X(=c&t{Uz{}nfPk>H(*OWw51YkwrCcik0EEG~Zt2%pRcomXnF4^S^yo&V"
    "RA-O}05P}WI<GQ_+@c(QE+L@t85!t=XTBo>gjf9(04f$NO-xdz9e&SEL7Z7to*B5=9m7EYvvLCOsG59|!;g(FqUysVx>5kxEySdj"
    "1ORC4Q568Nk|ibJF&*HKuWM*V(s(7(lBUTJLzD7B6##&^s7HR^msyl_a4oioH4PRHYV<g9?EirPilv~P>5m6Kb5?yuQt<ym@@+r>"
    "!-1<i9*bSlh&-s^lKTfF6_`(lN7h-<)e%o)bagSHE&_nr6ae!1xAD|jzbgQoDgF-x=rsd?-RAVLoeTf~3f_tc;2SX5qY!ArUt`Jm"
    "Vq*|TEb;Ny;Yc0pi49cAsM5{%N&vu<TXJzjZ1j`$GUy{0fZ@=7V*ubMy$=H5v-U3!0Dw0&H|6a=4FYCX#nC|p03MrZQrz0KI)?N("
    "-&W!O004wz^#w)T3^CPKMgU?aLjnL*yX$H)hYw;NT<jR6%juGsBlJ8`4Iuxg9eO*Tc=|PZrTTp~xf%(;I~prk8S~&|i5cWT79>_U"
    "AI$)OX%uyW!(RYMgaGuvM1Gj&o^TP5NCCH|m0x65x8O4u9X=VKcJj#ZUH~xm-Wvdvz5Jx34*|*m(BK3h06>WVRtW%1>8!Zo+m3O2"
    "F4a*WBJK=n=#H2cvsMxxxK`Ml5c~C01NxT%;Ik;$=JKrl{$&OMq}1IA0&rnCYxhnF;KpevQUw4sxwLZb5hFmw$u$oEoDH;^eM%gy"
    "p{r?$u{7cx;^R&c_0~~1vEUN`m@5GAqaFZ|x~99mn@>U#<%}bmq6+jGyVGzryn1-39M<BcVO-uYx+>=J%~n;x*n=E1h7X}uZ6gFA"
    "0Ki-Lv8kR40&anAQUze-gP;WWzfCes7(PPp4mZj8f<r>#dgK8h^QV*ik^0>LV0HJN0PvxA)=_7CUNnpV28{tgtpdDavhl;#022ra"
    "Zwkz|m=GI|9NVU-AG;B<Hg-`co+c+E&xL8CXEHI0xqQsjC;>ozJ8<Knb(JljLI27u(=n>{g8q9U0PxMe8q`MsJoKQ_{{;f*eX9Tf"
    "w9ar2I9v|^9oI3hF8f_vGVK4-%W#E&2~iD#qyX@;g<rii1ORbr<nWuMHf<_wp!hpS))F^zVr+hF^`{4bcvt8D3;<kGSX9-EXo3cI"
    "e-qgSthGH7PpCnmVo_D7@L9<g(SJb44vhCs#}6$r76@l66z(zN!^~%KiU6Pn)bOVB_XmK{>g&4#z{Oc^#^;CM3;;A2Xfs>HHkS#%"
    "ffRr{!%%*QIl&ZnEd&oBC{s@qVkPpjn7Uj7fWmG7Y2%U6&&~mt6a_RY2qZ4S2=GfBem9zmdCPTG03-mm`={?U2=G$jAteCdBdFoT"
    "ha&lyYH0$If;2**AgkL&J*6^}kO9EPc4qRc0|4OiT&K-`W5NTt)`4_Dgq+8AMq{B}3~j}+kj12nOno;p`da_TeUVdz?21ExKSkt^"
    "*TrAM3LBUxLM%R7!|D<MVv`sdKokIYNU*xHu5WIDst&~cZK@Oaesu(p1pqh&sE2@e1Ay>70pR?N0I)9sfUXcYD*?ccXLIgeDKq;Z"
    "CxjWXWQW|Dv9b87BLcY&xQJo|z>0V%IEHzcx?BW+QaFea4+z`(0~G>nkSqO$c|ft!$llnqg0iw@C^2l`(e78FQ$6=EoqnjDObGxe"
    "6_a|sZqJPB>H!qY_Af;-4TJ|Z$|klFg-TW9HW&a<s+0i0^L-8gKtvkwu{|*36_sWv<A=!4B3|BxycYxn(;7N1Zg63CH{Pe#|B(fn"
    "rlcZs98^SA=H{84AE%3Oh<+6ZrN}A(;JQC%4UYnR@W4`sgv-svKoQcyPmz%hgPJ3N2&g+`=jZQ#1Rx&3`n{Nd6ajotj{v7lj{tc9"
    "po~X{d60e82KPAtpz)q!JolCXKnw|dxOYd%6gN}E0!0A8aBgf(mse~9+NG|XfS4H=53A$=zbth%A?(0rS4jm7`UYhKy`~3uAOMlG"
    "r*E1JL*s0_xif4}$CYs@0Qj>W0FYwWc^Al>nrbpif{0lwLCfVbrwB<vJJ&?nI2u$()`F<Gu`u3}*-8QcV0r-XENW{QPMqnAvkjXc"
    "L<ZZ?nARV=88{B$b;R?T<c>Ey03a!!WW(1ee)`&&9*GqYfMWjR=7NSv&8msO@Om8ZK>(vUhDHCU46}vKCEpJ$(@^5mauV>2C^d+z"
    "i<Q9liU7cXHO*41!JFm+{7Mo~0RS+5=<eN9KwmU10DQ{<z>i>91^~67hazkqSP-V-wxVWp!voypsA!(v?CVIq#2hVV0}merG6W#I"
    "vPMUj*nKKt_Y0wGFZQ)g_5A(&;Sj)Y2mqW4u!a@y7-PD+X;u;^er=kq3IT9*pUr-t3uHEQ2FwY3L>Z7k;qh@hFCSBgf=`UmAF~l)"
    "cRFD@I1oTAkC`*HCK&bOY<3hD%xpD=g9l$}1AxAWTT&`P1tAdqmlRVt)LMaIMEn<bm3c}c09_;77r@60p`|zmn5dATj%nV0F|tge"
    "<_I8mf3^cjz=Z2}ToRCaVDb%sx$lnV0p!YnXU!sjjRF8CosIPN^2kDB{jM|s@NqKF0AO_h0C*N@!BDC}4iF_J19{soH(UY0lsLDN"
    "N@lCMfc}+XQHbmYq3_osKoS)L1&$gH&%hJKPOs=&gT7TFulbRj75|11pb7vu2*5@3^|YLRnw7LL2Ct_<fI-!Oc%PaThiE^dV3g)S"
    "&YkJV{zx_->O+Rjj@;XfuqDqxAjam;6?yo(jer38fE8tgH`J@Ep5a#0aspsL{0su8z{#fnuFVRf6u5mDDlJ_9L9ED)RSAnB4Gu&M"
    "P|7aLLx4jx016XKw=M~oc}9*_Qv!hQxu|Ma((ft&U>rtiA23<gNyv6I6A(n8&dG_`%Fi#(8&H7@05E$<{Jl7-m;hk%>i{t39&%+E"
    "Jx$(=FtyP}T#hNQ2I7FFMb)p$iZ{Bf6$pSkQ;6)w)Ii`Lq64IXgB80+^#3E-ZFDuB)h%sT7!<qPfB$|k1kjZND*=F3T*uOt11O>z"
    "D6ur+loSEff_vA|7ucu;XchTLstt$37}LF`s}Mmp##L!4%h-mk*^K$0oRS|#4&r^P%i;GCq(5&5PB@uwQK!o%XH*_XdJ_=IVQg)P"
    "8e+mK#tiDYU76Zr3R1Q@@2MQ<Ru2P1i>^oWyfpwoX8;5VGy+%YyeuC9lrrGOS!D!(O^tF6^nXS@0+av%!$#}+j^9EBKI?EEpqdK&"
    ";oNWoJpi0^!LO_sRo(yq?g;>#5&&3*Bp`GV5`6^zf`-4|5D=qp6R{ioA9t>HnyITs0koxq_>M+GtEQbq^%SvNHbnqGz+_5tf6dN%"
    "Rr-rGPyD$70Bm$r`)UB77LT4LDk8_qqG=O{p)f@N=GqR@M7yg)#o6W_qdig5!+h)Q^X?hL&mD1spOtGIzK?Opa|}g)m`!4X{N9Q&"
    "BN^Nud_Nq5sz+pyDbd0<X70^W0#MCO^3e|oVDxt)0c6=pUm?w*u4GD6_2J=OU6Gr4CEYn9vY*e(NgDxtirkUs<a@3(0Kmk0V%DD("
    "nSknF&Nj6n!ft9F;B4+i)=r=Y0AeM-V-irhyyyn1ZU*X|t83q%{>X?xsP$F(zZL)pii-eHiU96bhjd%O4Y=Vj0SP4JY#=a&qtStS"
    "JV5}haLyxwN@kfiUzUc#IjjeO<_JKuuzQz%UbLn2Yp+y^Zju6k?X^r>x2~mxn1RKd185cL$r@L|h^P=Zw3rBVWuwLVDy1!Iz!7Wa"
    "#|tKVgPuI`o@mPVpZIDn@`B|gAdc}U!_oO0p*K@<x8?*<0|9_z&jwTr1_@}wMf=T_lA)uEFKZGa?Q?|@+sGIoeS;s_i-ZnG`JC!r"
    "DZx0;tw=rNkRod+ejp=R5dZ)Iu-=6FMCjKt0WZ!w8Y(b0(Od%3lUiY(D>H`t`|x`N<!4F?u@nJ>?@I)d%}ewL&q|iIC8`YxKBa6L"
    "0l>FB0HD~l6WO1Slf^d46aMfO0FdpXYv&LEpiPrHHfWAHI9t~iING=7K`Avl2wYtu3y6Q<|6kBWWV)kjI#A&Z+7tm$wxEp^sYAP0"
    "M1XPt&=dglN%mR*z{={Hg};~WtayJt=<)cnS^-=<i%4q2l&wpBO=K;~fYkT{0NCxHo|&UG-#+tWuf;creDP-Y%uK%_Ik`Cc&la@d"
    "PX;vQo*VQg)L%w4y%gbyj46=%>Z*4}{NdOEI2phJ3oU+FD;?0nEM|<<P##3jSuO&o=vNS}Ku8e8W;FmHsc2xGsTt}r08s1i8JxJ#"
    "5O~(>XjcyoaUTR?!0#!8NO*8|-bv!|Vi_<?e!fpPV7(=x1Rdo~xKzoRsVRU;0Qk1e^#b6D_p~1%TRg{qg>6P7OGYng1fXYl=V`u6"
    "s`_ErHz=F9H_Y2USl&l2U^<%8rZEBq{f3G=L`JLh<6;uJDFTeHL<7<gWV^y4R?~|j`)dvZz^euT`~yv;7sY+tm#H<RLapg2l1hxU"
    "kS{OKh9tHX%MhV&#BLQ4C;<S@O&|i;Kk42e#nTJy^Y<wLe4`y;JD+b65`5gsyqq~rz#%0{dK7)3f5Rfj$N3G~FIO^p>)J#XGl*zn"
    "{BdBbC`SOBihKd>{MXm$0}ib!09ZO6a?Uq7#yPiR7mon)M4iv5*8qS_8z5;&Ur<tx+6iP$zSIq9yk7(mxJE}&{ef^%!OqOY^4$E!"
    "0Psx(0L1M?<AK?+oxZX;3}syty`7f50uZdq1aHy+h_f-vxbDj(T^8SD&eko6n*iof17a@D453SWv?W@IZ_W)1*(_~M(2dJg=!OU|"
    "x}w5i6z3y|J_XrRcl=fW&}IP-0RSC6^EsrEASU*&hQPiQ{cvnC`d#X+^ON#Na{yR8K0j$g6rZZ_&I}de&2SZAH<p?B*DcNhHpl;T"
    "Dqr~k02GnbA{_{r&Txu2t$QW1e*<a=<MIUci<oeg6O%{)UTrMqC^-On8&wU96d8T`1io4PsS*Ipm<6azr87$d0B5Hsx{`V=03^-0"
    "^u^iv>50P1DG`C*4*>9Df?em>{QvT6vgBdTxs&C~V*r4YCIE2%u+A-sAW9@s!z`(f?2GsU&Fs;1NCl0!lqkpP%e6=eQeKO|UV^lZ"
    "eL`@yfXk-cv{3I-fgWT}Vs?WhWX3qz`ON^J83MRd3pF^wLChea+aryE=*<8CPtycO2LYg41c33CXmu=n5F`Q&W2ELjbN~P`h?Mo0"
    "1Asp(&L}ve%^pM_K;R6v4=e~lRln^k<>!bBFkK;1Alj~(lk5zGAf}v6!dU1~at&{6&>OB30Qh5FuL?%T&UAg=KYW{+lU1Dxlx2I)"
    "?e*s>0Ej|Rg>5xgSq6ZVSW^Ii^Io?x0AzK<^FsdZodF<_PEXRBVe&PMAGe3JRYGzSfH2JEJ&pi?+yw_7Grpj{<gUb5HVZon+<|iw"
    "4GRh0Vs0Myk<R$Hmf`Znry>g4wy;vso|W*lnrllY{tp2GoQL~pF0#X>jVO%}0G}de4j{Uav+flNYIUNZzZC#3&Wlwfd9b+}m6>yK"
    "qNKv1iyi<n+OM;HkpS?Ka~L{30QSHKq5ME%J5&I~mjh^t%_f@%I`%_LbVX$Wh{ITF8W5)uwV_+M72T08Q2?wI0BY}sN7<%yHKO;R"
    "W-fp`LZ2e2+h3Ly003qL?Nvce9#aDVdU1_L06<58v$T%Lhlq=w>J9G-0K`T>^GCNwsyvRM^7hb1f*pXY=W=QUYPMbDtr5VL0swe1"
    "Ar=f0300FQ9e_3Mp>Z2@5+DF+0-~w|05A(ONG|FBePQ)K)@VnjhIV}71231%0&Kkhv&IDZKV@}<mqKbrw~qWA5p5v5(t!Ynp$5Hn"
    "M7Bp3(4^#=@Fsu_D2(Msgr-TrmpA1AdZiqI_*CUGe>z@3o&gR5fNTpIh`wMQ0AP!mQKE;odUpzCCuo16BIsC)k8=k{fbEq-f`?+C"
    "hB(A9s47?vI-=-2pgbz_V0JSApv5W|C`BH1ibp|A@i3}vl>qRG8wSikN#>)+p;QGpPu%%KV*n7nGYJ5Q6aX4?E=n96nEjqfK#Hga"
    "R0`s+spw)*pN-w;ubq&?VEVF@1Z)TZgQ6hF!^01$3Akf2D5dg;BK60rz^n;K_tjV5C<s{8mI*e7>4F7B?V6v05d*;&Vg#G^5hNX?"
    "KG^@4h~-8o*I$Z{T}nE53S*AC<hmS>4!As4KhXx|XX--+n&R@IwWiNib*K}VaZv8kX<P+39sn-NJhEy4C^Dd`000O6KQjQJDgd`K"
    "{keZMiVlV(-0XE`QvL59>ToV*$<U!3Tfii?xm{Nj)m=^pfGoHgS5Scl-ID|WE~yR3K9vAaf8*VZ2*A~by23Kf_ses~sR96qh1ek_"
    "o6THOzQp4>9sooYfb#w#33$QGoQ^02=2^JNFGcSR0GF330LYt803bPQ$vIdB0Ph$8P_KES3QU@Ssw%Jq03i!b_;y#&1oTpN<~8T~"
    "Xy;!NuL>Is5E<@&%&bX~IKb`X&%}MPmt{9W(jkakN#!FVFrSKgRFdvNxr8R#xYaoTlWSNONts+;BKD^ffP?mXb4UfP0-xuX%7A`7"
    "58&K#3$%mEBY-NUQIi9h$QB?50B!+#oecPk{c|ZLPffN=`(f=D64fDJM=s75IzZwR$!(gp=+LhOfFuGSv|fLmHv<4jXej_ttp>z`"
    "U}*WX!^#L?3APEH9lxk$z+l)ZD}o&b0943LcmNmFNd%uKVnFir5&*obAc(lpJ>oy)0HDjQqSztd696(%P#ifjRbV8dov*1Xuw51f"
    "CGt~}nZaGavqS4<$>khsx1pgcqvQNvG!F<hEXanKP}2;Gm&T$S4v(k!=gNw05Ma?sOl?;VB_wUztx@Wvi`KU%CS?IlXaZ9JK)Obz"
    "Lkd$tJ}5_|@wjgS0LK!6s2!j*FvK6pB44HJBpW~l0L->KY5_t+J_&?_{xb)kkGq0&?Mi}-f1fM`h(6I~znfWH_Y+A!4+7&4yfx%M"
    "VUDwS*+~JwL?hs$ApitP7LZy~Cti&&!0~apbgh6{9WcgvGt?tsFf2;~%KqB3dH|3_AnY_?4M^I}hm`+wmT>~}0PxPDpwhdiSp<L_"
    "fJ_2GcQrT+0H?<T06msh1vXg~*c(@gf?63WUlSqAO-0(NoN&}cjMV?FFdNZS=qJShJBwny>!r!P#Ku$z#F@lHqb!hZaWOL*=|@FT"
    "1b|clQCYBEO(>qea-h16R~jvEaf}IbUP-m8gUvuB!>JL$uImMWMyN(5I7rHXpd@Ph=-njup=}2uXhaXt>)gQ?A75W*gE{yy=Hes1"
    "w#ugpk%qtjCUIZX<*4yb903Jnu#=)7NPXg~eC|g{zfyRd0KkGqi!{jr2rVKB09ITF07NrJSXT`I5S%cmUqF!q&;dZw4NxBeBvjz3"
    "W2wJ*u1n(<0N_2Tz{0yJa!V3FCX1hmt&4<rM8H@B0Gl@gfRTQUBmP?O|NSHaxGM}%QEmz){H^6OK?q+NyxKsuBlUkH>y$$=+%5Kn"
    "K@sZn4W%5$G$6tf0&$dUbRCzJ<G$Q}A=Zedxg1TXsAD?rR8ZNBm{_)5d&F`_7S1v_f8_bcXl$A_0DzZ`drUJB!hc(LOv#8qXmIz%"
    "a78(HgZ?Er6f^)W6_`?^Jhl+98_`#o2NcSOCYnMFb9`C*Mc!-T1|knUiWl_n74f2pTR>UD&HeKr_a}iCm-+}`@%4@Xz<4(RpvB|B"
    "yPb|%2>{F64wv%%aT5UOoPVeR0MQIY?Lc|ikPn9d0MDG-vhT+%+p*0+BGhM2t<;62tc)Ad66n*l^`=B-9lRp|2vuOg(0EW)fe8To"
    "sn9%KyZNG;!p*?m?HV^y0NBrsU=E`L0)Bqt|2K%^+?vfm{yo-!b8M!63AVw~qy}Wrj;{Hel1n0Z;A27@@lcXW5ZOq>1U+BiEznrp"
    "8*!M-J+Dy`;J9u;WR^KyswKQ6RA8Ezg4R;eOe+4FvW}wc6PoHKVU38wPg8&*dqDxfU>;57oJX_V>5PG#WFiEhOf3jU&dT9&nJ_Ld"
    "uY^3Li4K8c1fT!_*8w{M0Eh`B0l+>u9c-fjfLl9jGN91StjYm={<1vp76n}bx0C~rM1anRIsi!8f$KVO^Z+ncIW!u369B~AwLvLv"
    "yh)7Ni|N8&Aq|FyjUoWJZv_BO0s;Wc34~RqE(3runS>Y&VG{p83TSoCi>ko1ZL91oME^^f0-(~hVvaSft<d4p2`B+;s4g0`GDSFe"
    "IjN3hf1E7~Mv6rHkdU2D3xP%TMF0U^zpJUkedOp`xRIPPx1b1gC<Fl0Uf0K_(F9C~gy<nop*P@2V)QIQ{j#Ozs?rOj?FPh6<i?+^"
    "6B~~&)C9C~oPn5SxY2Yv+Y74dG6fJPe$@OhuhkOGgL9LK4Pwv~EfrE3@Cpl5l>zC>(1ihjxWLQ=^y|xj)}~nmAe&>l2-0qEKbI7N"
    "aM#fY+&wFNL=0xp^v-Mbb&CKX1wqa}90vfdB<zUhSQ;YF0~+5l9avspIKAft;5l;y&^3*b&8y%FBy2E(>|X+aK@I>&6!hWVTp{4_"
    "xHp(uL!7Ba>P~CR$20~<v;!@ipdi?u`QY_ulX`eUd2nOnQL11pRExgKfnWSOx64}AfNQE;(3{)a&sBC~1fv4&4O=~U$%yh@`wF2I"
    "jRj-{OB!C3KuHk*C{8^H054h=yAA-7F=2j{PZ&ydvup`Em|E9j9so%Jt|@F`aX@P#!~yr3Bp{~1PemJ`C<Ls0BK;)VQPi9-{QnzO"
    "2I6q&>&~bd6GH(2^Z{eM*rB$utQ+V)Kc=c;%0jPeyEyROuq3z`3&5Zc4hl%)#(5C{@b1flfzGw!T4exeBngJ3Vr35C?v9dYcXw~k"
    "0c2pGwypKM!(@v<Xkd1`m%jo4S9t(nQPA!76*qkYW+r}Nhun}Ql^skP{&rVV1?JI=x5^n{DYsry@6NB?tJ?N{5!$1UQy&Yu=Jn@h"
    "w#)+n|Aj9%A~-Ok;Sd57!yaf<Bay~TLWdi(aB@WqbRYzHsu0}M06_1YlK<86MQT5ArRlZHQX&vCl525pNdTZqw9H?5(VW_WDd4+D"
    ">UK3*B-&BL4s>~B0QyG1K`W#{(<=Z#rU-0jiSPrB<B1aWVIDw2$~i-$iY1!MzI?g8z5T*CVBmlXV)8`^07^_iIcn=S0>JwX21#-("
    "f~ArcToVAG*0oF<_m=@66$Fv0z_LH%N2s&|8#+-?A=03k0Du6qd!=MRuDUftg?-xpxpBxe>hnhV2%tFtaD*W<NHnGh1JL-$iwWg9"
    "nW@`l>EKEs!1JL1K-aKPo(q87zcs2YjCi4YrJc5+IvH^m-va=c3`jIz(e7tX0CtcCO<QwCkKnfl$o6fmLSv5}04{R?;M5M1S9<}f"
    "I{|ZENplrq%Jf>FL~yzMWLhJrIh$v2*#-b0i2&yZ0Kj+~0N|<r8~{)R(7*g805CNGpsE5x5X93+f)y2k3Oa4qvdJBcTPK$T7*!9y"
    "MeUBg6X^rDUfu7F06;Kxor=j2&k#vX9|{t2V3|4pHzLg-^V&)v`Tz9rT!1s0420TW;2&sKa;Y(CpjX_bhr4Elz@oo$m<pT+fI%Gq"
    "V2gjA*^Z?8*dzcbhyh#T0Y)MLu<<6=Y%pmG0NI3WvwGA|82}CporhO;dwdBYK!AnCO>s7eB1n+*u>IpyUnEwSn}HH(@bd#XfaU;D"
    "NCK{Y0|0b?699Zuy8&~mz=|S}e^3*U`2jb%06;A9U{n|yI;~Fsf#`K}{h7K3<FWr6A^=KAs50e<^U?l-?lC4S-ee;twCcs))UH7Q"
    "n!}?{U;zLwa)ZI@<iK;2$h%i^+@@;cBn6$2iVR}f4!nQTL;%|PWvj^=bH8E{^6`!k3QG9K7!s#b1OQNvjV5+5Zg>R90Kj&_cLV^F"
    "i2ZaK&pYQLu|&Bg(KO%Vmc9b9QYQ%VK{WLh1%ciP07lN&-v9u{5dgq*J+tAUo8u(G-Ua}k$^{Z^Kz>EDo3{#iSRxEk_`kg2uAu{|"
    "AXFLO1^~Gzg*p^Iefnfl8`JHLGQiXhbxU>yjg-pipf4Mv;`pl6p?hK^P$N<_0CDJ3fLpwNY)<ts^#lOEf7e6+6#zh!Ii?1(zYl_r"
    ">je-BhN$2KI^l7m5rCay6^<JMfI@~_9CHLX3;@C_5eCrJl&Zb({R=7Htpk9PBU2r)Tm;DL0dTPKwj99wbpxj9VB&=20H9w70PwpX"
    "O#whnyjF>V`ol#D0K8#or!%u@ElE3uADtC4*jL(p(iiQ&RLQlR!@~jJ4gfg{2@!{o_y2Nplb#ER1!z@F8(d9jKIqevZZP1+tlH<O"
    "sMk~6KWsR~41}LCpPKR}<r=Dopd^xDPy6-6Y!m_b5k$O*0y3B-(|P@1VjI+%D|v!c5HKcS2{!_OOQ8soNP@3MwOv`x;0*x4T-;u2"
    "AI>t2Egu0i5dfNdO8g)wvrJWXt9gF$HUKc+5dfs@b$<{}j{pFu0zce$<@m4eeLVm~zDjsY0bsFB0N`E&0BcQGNthr22LN6&{}&-z"
    "a-R(2%B&bMOLFcMm7C#V{~rZavXBjq0Lx<WIISpCX$jlETe(9cJ2u<B?DJ6ol=fa8Q6Q^oW5*eqQd3x&XGgeyLRkh2J8zPoUgJ@m"
    "1K96h_G{8I=D|Q#jCNp}5jLx!4nnXwMqDAL!E#3clws%=B0AX8DjCeQ13M}J;3`r9pq>gSbBswl@WCV?=sQ&#^VtPsY=a}fhvHPA"
    "vMR72cxNBpas+r+O~A1yDPaRQ1At5Q2;e03fFb~(rIQuJx(9ebs=xyxfFE4`VE~Y&pl_S>2ymB)f|l>97ld+P^KCYv+0UjTNIIML"
    "1`F8$?8lbhKsCe<y|(}W_bgGcU*eJR{35C(gQyu-_YjU((GdFCkHCP`puhVF{e&8}n@6!^vil!D$k@+YgI<aWH~8;n7|#tN5W0Z~"
    "0Eh;(ubN>_bJ+apbTW8Ix_^k1>2aqH#>bIkI<sZ~z=;YpRw{Wgdl)p;12|X)9FHvwR=l_<(Q^<Fu=|5tU6zf~Aja95#*fw9uNcbH"
    "#Lfy4z|?%#Za|p^0_FcQNd$2OAil}~KviB6v!0pZegE)qUun$k@RYHpj?e)3u>$}kqQE<yD)2&6s7DN7aCH_n+4M@fp5(A6eD;b("
    "fCK<=!-+?JBb}t{o5bMGG=h-m!=L$&UkhV`2oZtu?~u~{Uv3I^`$fEKD~Jxr*96fJEV<pIP}wH;BBIo!j_rzfi^>&}_L2LGbIcnr"
    "8lmJk3Y_^X*?bfWYF~}yK9A^_Q~!TdkSAg(pb2!Kbf*U-sfr0o2s2pN1eyCn|M_Yi3<0)sDA3kC3;>wtVB+w9enDA)3yLeTnd56b"
    "bS}n8)d7HVZa7mY{`~MoCx_z{ZCuC$#`(FJ3vgb{8nFFVRbXT|DbI1`PtVdsP;Y7{U)oMbT=PPEzP)*9VBZQW!lj|$WO&>bONKO}"
    "LBQtOhV!`*n+v+H3)>C!3WnVO;DpC5bx-v6H5Cn{!+dHtU#^ocufKd@W{5D>Az9{iNc|w77LR4YOcNDl3?Yig-k~?(VQ2>Q@?T$n"
    "z`(RO(Q6Z}yo17yQTPiJ%#TF?&J*AU1)>FLnkvgVb$jt@YGe9Ov6dM?G8ExI#;Ez)EVU3~VKXG*(;m6j+MyYp5rpMT=Ro^Mz;a`P"
    "cDQPw7a3B=uc?UTvMM$YC5Scm&mSXXNZme_(LV2~_JM`93nXH2ulYAW^r}o~^%htwp;7|*RY@?YAffkzoDU+Ki6KqKgICC0Up|;)"
    "*iyT&^xw_q$B$WJ8=4uJJWRbI&crX&x+Y?hDOyR>KW9;eUW_+&LgqNHoQh$OXfBUw2HLS(9ZuKAF`^+ZRvL9yEwOiF7Nqp}+d|_N"
    "9xF8U&^v^LqKChRC*#CHJQ9*S3~6v%vkBwg3c6XT#nW)*9gJ9z*zm^xnE5oDi9gGV&Et8MG_5W;pv^OzmtAlbarj^H0bFGs<S>~G"
    "7mUN<cnalM0^cY+czGa0hLt%()xmG{@j^%g(jQF9fCfod#*scXN{Z#Z1fx1<>2o?tZKczrmW$%$f!ZejX0MZ|aTiK59sa2`F0A*!"
    "w1@+&uz%4KWzVsJlG!K6&9A0;Iizkg&d$++?<Pm<fF8!JEig;agEL7+kxg=D<sJ@Kr8rQIF;oxlV?Uj4h#-1OXNAf;MT1n{a?+*2"
    "iGJhf1xZdUz_A`Tjtw;byrFriyyWTH6%uRss2EN-_M0Eey;WjflQ-@A{`fy^O)?06IMJnOXm(&Vq$~NIAQ`1YXC*&b2ZvV!8qY+e"
    "vhte_c66zwTb;T|5td&W5jokSh{ZGF{9>W$MP<H{a5MGU1slb}AB%WD8s=@PP76Fa_TKSDmH#9;;H1lzr}EJ$+b@Tz(pEW3=XdgV"
    "zCQDem!uwi*@EthKPOg@SVaDBS)gx7jg1hR2L6b@^vB6(qq|1MGJm8WO6?cT9k(W~jGmcX!{y^?kOylMhyHNYYOI^>%zs$?b^O<_"
    "4H>ezwQ_`|n{QJMT~BxV6R}ivcdwX<S#GZ=?pJ>JwszoOGI?!W4Vsi6{x4p%%B^?v=C>~WUf1}){sWZOz2AJP_->WG<qfze?Sg8p"
    "wSTX*0MJ@%EdaFET5Bx;wANZ{EdaFET5Bx;wANZ{EdaFET5JD5&HqmWKx4)XGaml)wQ%1%Gznn*p4^9beYxCFlV80I|4^}B{FCth"
    ")Wvcn*GjNp%Jdlj-^;Y{L0F2smH(dv0OH~{VN55S-e^^2+?{ur^y($Q-E8&vi4wXT3j`KfHvNK$g~<;DOC4;>m6sCD!SR%YL*_Rg"
    "d3T5(I*q(HH{8nipYeR@8j5$%j4<g_f?(w*1LVBJL=vBd5&1^|dG3cP>m>C%FXM@;5<;YK2+mnR!##+AKLQnhnqGaPKv&IWAu=St"
    "aQ27Ygl?WPt)%Cx&E17Y3%p8l8O57D$UpYWd#Znc$(${w;&1!uqsK9N{KiwOqsh>o9PU`~T`#rrpF8=*UQZC0!v>mi6N?*p3atQ&"
    "(b%(k@eLPkFR{|~;vN38tB}W0;l=4H`75GfJMnbo%Ap)_Ea>LGV1LKZAhCF4m3Sjlyr<EK-WI-~HXFY&T{@r_x6y;vU<^5c+)H^}"
    "Nkag&%J}pSlxt-3U{kya=5UTiJnA5x$YwiOAP30Rwm*gA>BKHdhSHz(^jFkR-%}9qj5_Iw3HKdMHoOMWyc~|v1mR0fH3%+_Fv)Hh"
    "(P#?G<W4ShN{IL7p$UrSvS`;1@IrhH0EV2%1}!4d;xkQdj-<0H-9I_GKboRBjqrThD#9^e7~I3Kx&w*2dZ>pZckz7r1_i&@mpg&l"
    "xgi=qLh(jJ>I-m_!9juec~~j4rnQE>YtWCjX6RWmhvA{|C2>Io<E@i{w1Q6yDDp;!MDwVFOZ4(mL-<T*=z~KGRWPdD%F$4SS?tLx"
    ";Fr<&TJKz|Xo7_|qhE(?9dv#nBui#<!#tKCI@M>SK?b>SIjRa>$Ml7i7eM!wgK)r!Jal+@4uGKnL!7oKG)+3T0Rg>!|KK=ktec7O"
    "VfG?LZ;O_bY08V1UN|(hPBCxHFjp&wMMY+$L&=@BzE3}(cC@-h<gDmZ=0!vK&rT8?$y<=UC%8dmiP<Wc&R~jpb0oKbzej!l4mLIN"
    "LbSZ0D{5ssYulvWMl0z^UC%{xwnq~k7BuclqezUu=ZTN8BHdP=>P#B$UF!A4M-|J>;SS84NTHF$TM#hA6ivVmcRoW3cEzvfxO`bF"
    "qK+`;-cq!dDw}ZVuq2C5Egf+Xa;Hz|s;X$Ti;6D*e-8ZyU&X+6<gdB<24plf8HS;@i^{&hhTZEc$Jnq2#H=0xNRYv*9u8>!5&#4k"
    "(g$H4r#=cHB{wNqp|wY8yP4@!qa`{2hO}j1_y?1stVtd6KtUePv6U|kvBA~E*wEW}+`_><e=4LjNQE>Q4(OLK!XEQB=&Ko2V=#~c"
    "Kc+v1$+YwevsV)VS5ylDE-$?)n$NqJLObQ^z{Me*rPl@B2^XKni)W0J_^30Qr+rUqI@<@*MZr74f1jbJ6WVkgw)gkwizoHmEfh0p"
    "PPUH^NLOaFt&y_vC-ku~mP?gvfeHrx>g!y8{VnX=6u>P=eBrBXDP1_$B55!EYLj+_C%&PPjqvaFA2fpI>(@W#RutN6MUo4h{Js?F"
    "!f%%YNS2;tS&2&;J!On&pP_H0%m<0(lC+_m?V?y$YJK1y3@wv}tY2dEgELKDkHl&!MnT{x!Q(xkAE``9!6X^eqOtCgXwu_2<CF6#"
    "@mvyba7>}$fKea-N1nq8G{(GWW4V;SQlVCH)z_L4yNz1bF&+*IQ2S>HE7j>7lDgWm#(oU|T)L0z197g$!jLcDcbgj9KGCqa3Nb5>"
    "++WBvd=uJ1G%|WKv#MJ*y%53<nOxT6EFRJodm_<1Ql$zZtdE~!Sp7<j*??Nz3_6>8maW4gUQIrdnB9K=h#?g(EVi}1r|_X>mXMEO"
    "nFu<rc(IXSK8*_Z4{2tZ<h1a6QoXk}&r%)*b5Jc-Qu_8yQB5M%#Hr9%;Q`w6YnIMhO|Il~YXE>|^<h94eb|-Kqb@d+jb?5RgeY`6"
    "5^Fh>O(-&91w@HHqlFW}bd~B*&20dHGNOKMP2vCPa~GIO;ulm4c>-lJ*b6g<<sjNrgc5$94J^FO|A1eC2A0ZaU}TY_zFz-IGY!rk"
    "M~)cqb$$J12`3jj3ytI@U0BkH&3v7tUZCwD)ti={A(ZF7EI)<I8vzEf%bL&9mO22SDOI#aRP8c;k2HI?$<%5VTP44Fel+W57<x3i"
    "@}}B;1psgx#AH6JHfq6M`uMz`k&FS!0t<1_L?pPAT7R>D(XZSUh2|_KrsxNf$QX9XYCU>H9f@czq-f0vW>Y?;vbh$t-*5r<I}#xh"
    "qxPN%0C?io{*gz}d}I|{U<VK30CMbU$mOgmM8lxpp>6iq`^8#=>aaOFbT>UQ5c}Z=p`RFgA%qZTu{|paD8lLI)2Wz}k^;cJlv5@E"
    "xIZLj#{htjwO1wwKz)l;Iw2`&mZymXu5}mytP}w5NTNM(R@u+&NEPM85SM9W<p3ccBNcs{0l@C(9GzZL2LS9kxb;^YJV;GoW7yT8"
    "L}5fDjbacZJ~0TwG$T1jh6aB^sD)<4z{4HsN<!>Sin)7Yhy!8=C%Rpd6wJ*nw7{Vho6e^6bP>SxOh0c;_Xf4M@$va(3%A)6qPcRY"
    "@u^m_@|Pljk(kW))v6bFf-AkuRIk?<{dA-MC@T_be7G-(iSn#a{X`m4%vDtLX;7Y_Ow%J@X8?HFnmGWNZ}(5)*H;n%z9#^{lDnk2"
    "JD6xQ70{8ejczh56VYeau<VIr92hUfI<&mU(+rGhG6Ct^Lj?eA=aVu3h#BgnqF1kGi8H(e02bv=E**w(@dwn-6RZLNPY(bD4Wx^r"
    "06-`m-V(pDuq|7CrA7V<l>s2Yz{H%h;8;)%0HnH?ix=$i0RV8rz)VLmV2BK20r{3(i)X__%hkN5A?;Sll`zmLyuD7QP_qm*ei3O3"
    "-$({VUf=2gpjQO|4I%&>{ji*0Ht;A4u5k#c3DbWY03c^B@8r66mD8Hrb?UrdVn7!IZOSnyjlj^jzx0QJ4gp9`O7VZvqR)@gLg;TL"
    "0N|DYfCuY&6u0C7K)lv&u5~Zyo~6!Ds)!EK^H#5W@JPo1khm?$pMR?dfQ1eKSi;(ythWz!0Dx2$iV6Y%{zT*`e=D6fP5|H)<y->S"
    "J`w<M=y&Wg04y;5V$BcO`C(OgMaK*P<iQ^Ek`k?18OC2;xs?C_=+DhD#Pv^RhUXIn$`%=z=`30DUO2l+c{ThI9u5m9#}}0V5Zqjg"
    "uRaArhn@yejePR}07UlN0YFTK!!kW(0C?V2%d6r;7+;pZD*{OGq+J&RAjkHyOZWL2JADEGthD}LDJ1?d(9D<)C%M^~1d;i9+TszO"
    "RUPF3V8;Nk-`V7hk1`yP03gm26=OH0BsFKL3?zh*3&7Cy{w1d7HU$9q@We<yY7GE{S^zMotLZ|1qXz(gNU8VPW}kcxS)o{onLYTZ"
    "6ctPh_4FzL;3I%knzLzYZx#Ve17#qk1b{mL!0CxuJUoc)LtXJH0LYwJZ<qoAW%`rZvsMKF6ygW?djbGSj;*xCxJEXig#&=w8zJ84"
    "QgnY!(-|=Og#h4_1_0;?z;dulD^36a<0isoI^AWd%aK8?_w4|{ckItJ0^m{bZq+Vro4*SHaAHmGp;_~$$-e{uoOA}F=%?mxlW+Uo"
    "*$YO#tx6ZFew4s=P@+O0Z}s>rT=q#!%CoG;{hulT>~{_}_@|d2v>b{6@SRg+r~>2xV84I*GubD#a@#yCy@z3fC|Vm=Vrrg!sH)>-"
    "0AR(#%;jYgusA#s01#=80POTB8fXCkAq{dy$crlHAbM|9q>)FQJu)0D^XeB9y?Ow+^F*b~4#yb)U^j@IJ3RoL=>XtsPPbXQ@Stxv"
    "vbgU_02p9`)+ulA6#&o&GLNnbr-f-C0HAM`$pTV)TJaFX@!0Ljg*_67CXYrqKtMoK;)?)qjgvo;fXk$QCvoH&=YnkR8-}}T0pRS-"
    "03heBr4hjQidpc#2LSwp(CaI?owa=k06Ogd+m~9~?}`9`n_oLkl+$8`4^Q)DdG-|Y{d5p`E(HMW#q>)r8%&;30AL}2<N4*sunYjZ"
    "rx$rZ(4}d3ZqgO%<8jP;KfbYS@But$+z0^R@{38F1AuY_z*Ca+0HB5g6;m^2d_9s2@#mgPAV`5byM2O-k5rJb)PT|tb<<@@SQY@_"
    "OiA6BMEcw)8P$&Qdy$y~08s^)0{}W&0LYyIG60CDg5H<T`{?i%B1!|c9snYvpTzr#Hwgfs+4UN_ATue1gCM(y-QHr)#cm&YfeZjF"
    "<o>P!0EPsBG+N*h4k!(Ll58M(1o#Z7K<(|zfe7HuIRH?AL?V{}pd+AQTU7}l0Jwcm0003j7J|8+n%uRM3NmYiRsq0_$HY}z2>|?H"
    "IIHr1SrjObaYr&tB)Tys1C>DRYnHj)7Xjea;q-|BfK46%Xu57REdap2+nN1|N1mkPlqWu5)F2ium7x0FD~uIE@e)aZUVS0ZLwYiq"
    "M3dzJIjuK&-4#FkeH{RV2La$ooh8VJ8J8-`kI&g$L7vzXs0*mzu4`LN1jR0Y=Zz9pEUNd(@7>vvt^T?M09yh;DF=Y8fi?n&U82?b"
    "<2(R}%%H1}0FuC9kg^D-;2}x?n0n&%ieW5!^$o@G_>aTqe1rg@2ms*!nEuRDU6u|20RPH-;SJaMQTYb|(2I_|1OPBmKDN`eLJ0tT"
    "*6w_J1VBX_xf1~Zwl#AWe**yEW*|glrUbrR7sjq5e-wqoQQ?Rz00768liHc~9GDjXfG7l206?YiBzxwSD_!u_8JK1>lu2g!lz?3P"
    "4kpx9001Qkhh+dbIZ4LamK@CGrPnts5KrLz2Bt#TR*$RESB(K+<5+qCxKAsf_n3+iS!Dp=Il9pS04QGmXI?fz?&{FYzRl2A1DnMk"
    "<kj;<68nqLoVW4SP@(UvQ<qmqajj`?#99J?fuq3O@`?bUdWZ@D`H5fs(+mK-3ILFVfj%PgtNwtUNhW9d6&w>W+?~DI;#&WWI11R2"
    "DXM}D2?P(H;!g|{qV7k7qv`l#nm3>1__725k|*f_z!QN;Z3Ix)wcyGCm)7vfi3EV>$9YBK_nnUbIO;6`;b6!5el7w40Jub92VKf4"
    "?8xL_q6%;<0N`L<82~)Y2Aec{rrujT3G*n~O~KowF;ouTfCd0&)c`=Dfd&8sggw2KrbZ^YCzJtuF%8YNY45*mLItAXdFeFT`Bn!2"
    "JXb9lST}HDJpf>?S}g#KR@=hmr&uNyl#<+|TV=)KlY#O_j9yEG^=r|8BPx4;jI!TL0pP2bBmOwylmUQp05(7174r#pZVs-k0RZ-l"
    ")8q({1Aq(&`f@leO|Pc#3niGyP2t1V@<x4;t;6<?69PIG<k=mYI0ArcnH2ndjfls<=nrrLkl<Zji&P&Dd!~h&K^Xv+5=S%uKywXP"
    "`oAUuAV->p)eA;MYytp8){0O&@GF?WH#hG`1Omko8^YQKo5Rg0-l*~7tc8_tad=m#<*|P;0Bny0057&H0st&>lns*U!MP!Bp5*w@"
    "u?RISB;;bNggp3Do>>O~I0zT20DF7{4gtz1E<YTJO!MH%n&RAV7-EPbRRpX9S->m@fMIkQ+}&pYfO(jMLF(rO0J9VTA_V}<S^)5-"
    "=Hvc*2?pURv&ZM$eBu1Z^Fzx*C*LTRf%_U%c|RcsWFJmR0)DlOT(&SAGXShlPkQ3CSRxjz)dl0R7v}-sDh~jI><EC|u>t_n*YQ-e"
    "4^D|^?AHST7BQdsm&7l|gc)oY;_!YWHu`I10I~lgwSzN0JQtjSFp`jgQ-Vo!zvZnf$3!OpaDAKQ01E(s@nuB2-dqi<BLF#sUC$v;"
    "0{{U4-KYK2_bLvDJmVO}b_3N;j%NRwqVj9U<6(Bx^QJr>Y)!kw!VSl71b{*n0OO#m{QsWZv72PThpQq<LI41#5kqy4OAo=1Ya;;w"
    "e<}cAK-`}{6QV$z@BmDQGYAX--517$kGVq!%|4TZ(|c1~<<$F4b9%77D+7RU+gAku9$pgwc=(3HM>oy(>j8kTLOlT3Py6p01jwHZ"
    "h$cD90l3d|_!8Eqn8X|mO*Mb-`Z)kt6aj!^{&lCf764GnD&|u2c>tg$-q5*B0N_;A1C)u>xF-Vz0K~ua0bHLieF^{~7gJErXR;qx"
    "|M&=t(Jii-!~k6Sv$!Zg$A=Nk)4;Ecf&>7fhzJB!9^kh+QX+u!DgZ#OcKZW89W$pI0Om}NuSn~qMO)gjurBr~*|mZ}=&KE8WjlF8"
    "2e1g+fQFXB=d{w)PH`G%1^~OG0bte$05)pRotG3zW+I#I3q(k^xAcOooxK16FXW$71dsuM_(lbQ?->9Tk^nMB<+XRoOkk!0SwlJs"
    "U>lnH4R`?TxEl=sP_RP@)D!?#lOK8jaGZlVfTt1y%m&Kw2({(M(oj7188@B8ET~gfa;qVF;vu!J0>FBm1AwWB0KSSx=Z;mHS8Xc0"
    "GuG=>0subA0E7wv$P_?U21IG_v~yVm0D5X7P@n*S=hI}npunjY0AR}%L?fF;{!Ziq9pjdY0!%maUE${{0Nh9b08Xg@U{(SExL!p2"
    "tOEcZioL5Kb4;_v{IcnE28l~mh5-0PL0E0amjOe$66R*g1pK;IGP|WpYYG6JBLTpzP66Tyo}Qd0PO(*)P*_3Y$p131VrmvzP3N)*"
    "@U(x~$oBxhUOh<w5KK4}2Bgm?IRZ(KGdwzH?dc<&^mRE`8cUtsK%$%&sQ)t=;0n>e)ih`X0N+%;qY40h0)T-60Iw1NQ1;5M(8Il5"
    "2LQBdQ*+eQpZSaaqQnKbKHIsYZFr<)V3x7V0DvdqQA?i!00qLpbgJ(81tM^oLDD1vq5lvQD<N=`&Hl81Ss(&Ybt&<rz9Y*8$N{92"
    "Ia2^Qo8tARR-U#lM#1x`JsL?(k1+LK;DRZO0&bdSQUQR^4+!|jJmE3O((Ovxtq1_?2XPx~0AS0#AX<M8)r$5LD$}`|j;Cv+bu2@7"
    "1TeifMF6m*%1hh6yn{w|tecy~_GASB_O$@;=W`wa=rmsffFvP~J^*#|3(Ea2aBrJ>r4vpcad`&Gp$UGyl1G3Q1^a*I0pR<7XNu%F"
    "{UY8sk_H3-GXVgFETB&vr*aYYug-8hiid&<MEuiwO#lS|zCC=?0zj7lpqmhehcYfI0szv6wE)096+6a&JnAaZ|0A_mc@<ry3-t()"
    "0Km|8kRUX%wN?W_S}wYyXCy3u_1W3F4giqSKr-bDqvl7hboNdX_owx~etIkrNx<YN1}3&w007F)(scV=E`S>TWEH^iWdi^@d6Pn)"
    "70V*wk~*b*EdYQ690%NUA8YGvHw6GNxqEBoTvav$aaLFl0JK?UPV}-FWaqc%mx{p8SYGEEfUkwUxgFR~ncizN$pY9}_oo$=w;lli"
    "Cx-yw`*Xe*K%vH~<ll$;+!q1>!u(`;Nd%(az12#x`uWh5)FN>NSbb*zpi%>s4WFS6kO2T9suTd$$es}ZWL4KqKCI8E>HRA(fzSki"
    "40PI&);F61fciOi5&*<$2LSNxp$q_11px3P`@XgpU<Fa3Ibpzajt-z~|5whmT4m*~3;@{9&BdC^fi(ayR`dXHrcTO<;Psi+0DvoL"
    "a%)vT0|1%v$3v0)B_%Jwn>^YEv-=?R2on}T@_PAw(igipcmU}9mk1!ep2Gr1RMA1_v!r~H0sx^T4OpMJ@Bdu@;PPr%4FJ9x0B{m8"
    "tE>@urJOe4GGIjo@U88@>2VM@j_6?Ona?((@-$Le20Ru3@M#BSE^NB-XWhYt2tZP$`I_u05s>+HS0?iDBasB$Kv6(kR4%0|0Pr%C"
    "mwLZu06_2Mi3kAbYcGGU$C{CZ^B#`<XK6S3Wzy2_{{jGP7yvr=2LWI+JJ1fiB9SDM*ip~LYyc(yXI7oKjK3}efIQdVtuPn48UT`d"
    "@!AB1Bxw{jB{R4R04~Kf%maXU97lXT0Q9C)83GJQ`GXxc1%OLQ5hwrvk#?_Ts4giueqde8az330L`DF0f1zEX0e~f%3GsAGTXDZB"
    "9RX?q0NX`101#<wp8>$^q@!?av}_<>Atk?CFMyY1guj|Y-1c?PN;zQmSR?Tyi9ihiU{e5qVh)gw{->Stqnlhq8R9zG3@BRvCkxpD"
    "yXl<DJYG@-KrHVDBTgFbw<-YOmt_aQ)5?B)<|lX4`b!Z26a={9g_dKf^y|`qO#tAu1OVU406^4;`)>#I06gd-LMe%)k#Z*ix={8o"
    "u2C;a8hqB|Kq&xx%>clv1_0UrZ<^z97|F+bbS6xek);8Egxx~`kYo4TXf~<>fUHXpN+6ur%K#ubC*)7c9;Nan7uXaB2Vw`_%GzL<"
    "R`lWFE+Ie(0B9#&3dTSa09f4DCIJZm9x8GGc`_GPZ0Dq#`BYl?`t1PVhDpEo+8$cy@17?|0w?yXdI1^$z|;N!0AS4{5rnX(^srY{"
    "5Sqz!KOw+mkT9oC6951QW`!_;E?GR`0y(^T9)DCy;?Lr6j9)b9(fw}oJxjlqT$&J|FX{k;@;$8~cc$HdWdPuhPoG%=z<mk;TP*-&"
    "C|NBCLITLq#G22Pwjer9LiZ@H)mTiLf|#{)6ab83xj>LI4AQg_mxbh09OVS30{|!YEgU!l06raM0H8b@3<1jB9|8dC`j@m_Y61#{"
    "qzI9KIC}@)4u~|@+$l^5-~#}x0su(ekGLTKY;kzSW}UPxr&>U1|MF~GQ3YV-mOmBF=5F&O=-q-!uL%L(9{@-cHNt0=oDU>cMuOUj"
    "N&pm9eb=vQ21-c_bpR060{~UTl9E_80MMa)uzN}PQkKcRfTDd;0)Suw;vdM7iq;|Y492fAS&(N8F#vquzkGknN(7}?i<<%Tr@C5A"
    "fHa^_YXLIb_ZnLR6#zD60GOu$aNigJgh)H&QeS7g3;{MXEA|c$K<sJ&@JM;;FaThIBm!gWP8I>&t;$58R4VHdNhL?UnpAqM1OT6I"
    "!)3}5B7x5w01V2MU_S_~EbULEQb`Wr2!PH5OA#VaW3U4vfD!>D$pTjXiX;HslmH;g5rO9DfE}2$VdN}1FB;%^phb3I>*U#lHWe9~"
    "Q};;Q;D7r)ElxCX=+wbR?+gIYdz_9S`E1(h=`H4a3io%0t}~n}!uy4G;KKm$au5L684gAOQWEgxIqB_9x~I6FCIP^D<;ebV`<TQB"
    "rUZb!@-{O7_?{Nf^sN_eIIL*#?qAg;0R#ZxBiuhEwZI1v0SLkmesWR?09jwaF#te<>4f1)IEl{)deH&V^ArFa1^~0b<xKz}%LlC$"
    "0I*ZKs0silopqTCoB;s4MYl_W!?~*og@8N&bQA#Kw0EipXhsSE$k!|N+CZO^1;LUY0FoTd001&7$fL9B&o#vaUKs#b4*<b~>>kRZ"
    "fa@{<kOaMuU`A+>(*$;ru3m-V3h+Fn-_S_o2<bMsI{f|nZU=Xw>eTLu!qW{ExXTN36ud70gpuvo>&05B;JRZxMD1ZK8%h`+wF;F1"
    "VA~h~y!sr#01V)PCI_Gq1+`~P?4|6e4D$I1u#sFIOZE)!Gxo1Y7VLLQr3KG+@?6=<-YbaF>JfmtRNO-VFiSIdX)VuI0N_*y01F8K"
    "8GJMX0JuLi<u{L6`UuLW=42Xp4FKRy1purBhtzakBB-o$EWkzL>Btz!GNA1g0HCK+lSlyIswZT4-LaqolLuc)rhg3p5D*)R9Eh9B"
    "iS$hIdO=weGzQIICjQMZVFv*Kcr{Wb-DG^A-e7c36#(FRN#f{+B@PZZpVOBzBs}CPdKga;CQ}Z0Rz|^WnoJRengzxI0H`c|)I&E<"
    "UD5-D|MS0nx(wLnN+G~I1Awa#{!-QtDh<}!UI^@8&%qKN2SotbycYm`LwHm!4Q>i|)uZt~v6B??q^u_;0c9crDgTsGouvJL#Ezu;"
    "_xHuFp<*ww*2BDTs6PeNH3X#q(C5$k@L(pMZaKOLV3PsBHUof}a-|LcfVYZ8lcWH?y(|IlzyPev0tB-7i}QX40G1UEM`IphG8LuZ"
    "MZ)t-JRL2=t8oGVVWu(Mkpe*_S!oFXNQOac0BuJ}F8~55Lk3hRI#vS!ae!q;7B4b&Gaf+1uNUYE_Tm^ox<8@R0wV^nFGcB-_I^?d"
    "Q2^i*^8l=fIdu`kM9KoZN!tbsLYGu`u9nB1ZGOyVSGpa;ixB|qp9ZX+HA7+jgaLs6?Vfb_U($5)e;)v#5#UY|I+R-n(Vl|Fla*WV"
    "8363R|9Joaa@Pt^EH=d7f6L1M>Xw%)10slm_8l~Koh0;kWNe>w^pf!JI-in6ws0Z=;D_2fPzC@l80zKALyb-aFWKq?b_xJO4eVj#"
    "OQP@0mH;5~9!V8o;}QTo<N;v!YHk%4aa|RFQh=HJqZ%R*fLH(w0e&R_$YVdX0LzXLAp^mks~G^uI=_{Of<&WWm;ykW1K=t^LJ4q7"
    "$|{0AL6dmglxdBt$lbmO0TNZ<5&(!sT4ZFe67|49r2_lq=|^Hrq8BB60CI65q)Q2bWd0fu;8wUjjxi+wpz%Y#o3M(lq@&o9B*Ov#"
    "K;&-waKL6|jW1EIei@u_9(?!IIh6oF|Ms!2yZGPp&dl#Mlmxu}oG2M9Mu`iAD@PK6Tr02U0G=jByNn9$T?;d;0)X$w000X3Wg^hM"
    "Mjkj%1PZ1T%bYLfQ_&a5QM^0@%#un3B*EtS7GX*i2tojmV5XJ>O91e)t)lk01xd=3+)<qbNCCi<d$}{y0l;Yr0HG%U;F|&f+gE4P"
    "005A|0T*ZnU8YPgJrM&S)pIZbCSgS`APe4$0FZFhB>>1&ft9oeBjz5-HUf$O?34#^Vq~jG4*>aAi~d!V`0_{(09TmCNH)qQ30U}("
    "YBP{V;D)CLk}{BR*H5HDCcwbL@gsC;&>Q6iZ@3nSs33m?xRLF^830(KUHDTK08Bnoov+gQ@iS<|mkWARbNftbtdl<CgqK|o0Lb|V"
    "l;1AW0TFKSG=rNj1rsoE`{l?SK;+OgKzly7ZLaG;`;z)D7q%+%TzLdI764+iUJooSfG?C!O)7$0OawxvUUp7l#}=)y`|q1nOTn2{"
    "1HjZ)_*EJJ_)$6T#~<qW9fKM&U<m+{ssMU>QUE~AmjZwtlmGyIgcvXKa0mdv0kG%f{?7_`#7Yw$JThhGR6sxq0Mxk?xJKgA1pt^k"
    "-d(=u#{d8%`9m5Zc9$@L6Ba-T01OELMKbTzG?ISpNXlQK3UD=q2n!55x9HELs^Mzb6F<}e0MS}$eve7R2gqOP41lcP4T%BXVn`5Z"
    "&Tt?nK>&DjF$VxopZZx}(QTqC#!_NB0AP^|WV2`(2I-tC^No<Bq_$7a?|K?>?I&#YaC1)icjXbFdm;gV{zs?iJal+88tl`jrBN6O"
    "cKhkem)lR~vF*SB!zn2mpvRbaKSK<GvuQ{a2DxEe)PkiWhG9_Z24n!}AK(EM0l+^b2$-e-)EXA0O7@t3Lt+<#IQ9H87|I@?mxRhQ"
    "b2ilg;ASE@S^(G#D?{v5luqdm8uV);fFJDU1F<Z&W}NW+G63MYDT(@t5laAIeZT|&Vn^i!>xIj~0^H<!0ay<}0Yd5q*vv72RNIB3"
    "06@|SzD{#5P!^QUe&Rf6TXC}0X8_<)6>MGX8C>UCRT2OO=`~XUAZ-*%0pLU-0$n+xv<4jz`3r=+VyuWB00JriKnswlNG{d)uSpJ2"
    "001!o9ntY`1=77g-+&L8CjtQgqC9;_<^r4q06yh!ey9LIrzn+udOFYp01b_KVJaInbv~s4@FW4CJ78KcE#sh2=0uy4P$5yxWf?=u"
    "dIJx@qrtb9AcdjNW8oNl!yRgf7`nr#tO@u=0H|&UE&_n6K@<q>JCUjL$nl?Fl-V9h8m}l4LQVb&06<(z>A5Tez^qaQ9k(fe2H?(M"
    "(}`-T0675IlmP&Fp-n;);9rot{k;kR6FgWS0U!`7a)7B9BKxQ*1em&UmU#e>8+meiM-V;o<RmaYBcfKYDggk|1#(k?vZ(?Z0FZNj"
    "Fl8qL05`f4KN}_hKzpc?Y7wW0UMdexg+Te>6?glArxN5o)$+?{S@DZy=O1M%#1X)B9gYgV7$kU=JQkLyz;s323;_7qH)dP`08;0Y"
    "Vtpm|CniF|9%O~r)6D`R1ptw?CC8sB0B|aZ>a<>i;@mSrfZ`BhAx!qR>A(;M=J?JMdXL}*u2~=e{qN&IM+I&U0CoWY<_$uC!h&BV"
    "nyHi+SZ(qEkhC3QFvzwjgteHa0I*6!01W^<KQ1bhY)QsC_5LoVMh>Iu3F@-tnE(JDOm08P06-@G#Z1Hu0HzWE9#jCxqNNHw0BVuS"
    "w*au7{Hh?B$UT9YfF%V0F%4R__;aQXZXGA*{J9;9d67{v9uRxY*iOrRC5=(pU7!Pi5E`CQ3~EUN0I@68^r7*s@aU9Oi|}<6U1TkR"
    "UM2a;B9+k)6W{ZniZ*-rFmnG!5dfAh`}8$EmWT%e0B&;tAoKu8=`SS^6GGe=p=H(qz`ZE?lv4nD0N|E70sz5d;e<9VSMe_ZKoHgc"
    "+!rc=U^(CfAT3{d<Zn*iHWP3`w-XQzlGh!^*z#RP{wLJSg1;32uv`v@0CWP#_YjJqezdx$_D%-?L=7k^;nCqq0su<wY1bu>5Xoz1"
    "y=-b&b8ga+N~$1N5CogXNR#^G1^}?e7bx==0U(_XS_XjmBu)Wfm1Y6-0I-@AtC`=qY78!XfuXG>I*!LfPpSNdDF9#_LAQ_P4imi("
    "0L2|Sbpil3MlD+j0AMO}Sr2Gho(@dlNh*B^HP6u6E13Z_bWHrr(3M-@<CgUGXysff05A{$Fa>MP>h%hWd0gN})RO{0AOYZdDcQZW"
    "$Bz>APz3<EazL^{G2WOhSOLTyFs@l*#AE;fK;+fPq|jwW2Jk^dee=jG)d2TY12{=~)N%mOPaiLmRG{9reCO%FBkl)YfYw2rsl}Zc"
    "1yecwO*<tt1Avz!0f5_|4<P_KP2d*>C(8+cLh)Jy0Glb4L!XMrk7Pao4Wr4fr}d)<05!xuG$QrIxgYM2B^>&$duYgm1OO8E*$td&"
    "5df5}fogwdlmft&lL0_BL7@r&UQ2u?`XFvp9GXzUa~g&@>c=8gf<hY2o_o_jWCSpzWWYKYr2v2kKm-qW1k}UQu;Ie^>=Z)HUXR2T"
    "$#dl%js`zls{Sd-)<H(2wM3Fo?H5h~pl=#I(hBYmbgJOk<7FW*0|1f)PXs_+5CFxOZg87Z1md6{DYj(_0Mt%=s{nwZ0RY_JuFg6#"
    "30QChDe9gAz|)iT`KK2KfPn%4xdX9i2QF)YCgY9Y(hkg;K<N9WP75rAJDl5tDagUd>Szbdi+13q0FbX@u7-y~fI<o|YneiV)D&x5"
    "0{}B;nok0<qEZF`Y2PI!Ret1u^QE@eCgemE=F(fBowx`1wW;tq0Kgv75zv$o0CN0m;n7qUqBEjI1DXzMNB|fNl?Wi24O$HVG#5NK"
    "Akm~aQ=JPS&qvxLPU6uvqlP_~2|UwgUT9?75&&Z2gdwr-rDecz0sx@=`r~5Hz`B4oslF2D^LUz{62vE8Iua$2^Y0oG3_uVtWop2Z"
    "1BEjHkS_>qz8aM@0cFCE>-QM|5cAhes(-08h#CRNUSY1Y-G)i_Kc>o?VO2!{G6{$-Z{2vjjs$?B?5vmuI7m+V836Pp03_mIc{U)$"
    "IJfUS8Vsk&1<inV`DU#N0O;=^2Z%_p;t256J$VZN)D8wnW`h;kkJ$j+-AvH_;L<7p@NDd1{^$#Z?CB~|2S!8@NXVdEVh#Y5shWC^"
    "o?1Nv*`o;I?%^@d3ILFdmFrG}1OV;@0MNXU6`CxZ1Q$^ID+0hh0YG}GDnvnJZUR<G&SIlidrWCY`15lG%|X=nxb)}71!1psB-_IP"
    "03gPiRyaxkVC_OMNn!yp5$yQ^00^CaA+S#gK(Ra@Ai3xC2P_TZxX#2V004NurUZp6$B)f?JK$Ab%3+zP0hrAAzfmIqQ<ndk-m@&_"
    "0HRbZ0F{JgkN^O31Gol$0syx<0N~_qZcLs`0?H#m;gso3OzvFaBp@1qw)<)T$OUi=0N3ve03;Qk5DrHxI_`NaJxGbgsvN++-w*(b"
    "wVDH5034ZS#iBg-Oh|&Ol>b`f6mdD+pP2dip+p-{03b{y0Sonl`V#=Z;~^UBr<2LpA2$I2I{^Tc*P*76Rz4n#1OO)B-bM*68onND"
    "0U$YBRwV%;4ht=i-Ag(KY%5bI>Gh%uMyCCMzRdeE0Dy{H0D#a+B7lez&R8BP0His9uMV+@oq{G{sXH%|Sk(Z))RyGx;g#T5_<<ky"
    "5&*Exv=6ACsxbx5pq~SPQGPV&jimVtVGwNgSrU*o^V?(&kU)ZD1Rw)|k<S02&>#f>m#%?J{NZaca5yXjz_<G<8jvQcrDRw#4e(@u"
    "b^wThvg7Y15C9nZY29k8umOJu01$ghrnN~Qel1IPJn^V%HXw^}9R`5%cyLOqZ)>IlZ)c?vo0lo4%i*9K+g4|TagY?-s$cU7Ajkk9"
    "^@<_@)Qn-vxDuF=V$WuF>>ddKxzgu01AtYgjzqqm<^WOv*bxA%CWAUfARn5TP;VIQ5}}0Tx6%**ho&Dtun8GM?Ld1809^Yo=JM8I"
    "dITV59r7OOgy6f-A4wIE^+?ed&qjx7=PZ{2KxOtLw8vRM5UkuNivZH64pR951Rz({0N|%R{h}X`_v;h@K1CP@CiOs)fgwSX12BpJ"
    "kR}273Z$L*MF0q71n`h!1AgP8;Qf6X0jP_IRPI=so+Iflw2-@e8bB+c*!)=_Tz5wOEdVf1N60e(m<MK=F#s@yaesUSK(o-VHV^mr"
    "+UbA~n}Jg<v8~F}!H24rD$m3VRVI)~KL&0F0LZ#-Mb}Uc0G?_Fu_~M8*xNwS!3q2(BbF-w;K5V?Anl95Y%qi>QXHfR0QR<aJUD5A"
    "Btufvge!B*WblZ{WuoWIW&pq`!2$rRG5`?IP8mPgAd=$%1p}F+WLXmY003Ne5t=0wKicdC0N|aa08r@1q<R28WGw*Xn`M}{mjOUR"
    "0Z#gR$-VtVB``e#$RvUx(gjIX(+`tz;TizI9qdXPplnk{0+6YJA_tI<0J2jpOT@D}Er>rI<P7&I03<<fZbZPl4+kx-iglrvOFR04"
    "2JUoEnoxl?%EoR;Y=DPi4*;{NH(H8KK{<&U{kfAm^<g^1d&)!{>DGSuBLx6g^bzC%;E81OCk@=1?(xH>ejq?PuOsOJC<4Gt1pwsm"
    "l5HPKm1%3R3IKjO8}O>S87P^Npl%aj=kSA&K8VmQr0)mv6KT)8aHIu*c^&{#DPRl|@MSardLV6#W^OKE@s8I309t$8G#VHt6l*V&"
    "WJM)6C&(n*Fbe?Smn6YbcUayk06+tQV`az}$Nj#X07d{18+8CM4k`d(C;*_}IW6S?0Rb~D03^E=ou!HWOgle8LFb79fX0NX01*E("
    "0KnzowG$r78Q=i(@;vCy_VvSo>3FS~-{h}oz@O-nAQ%w;;Cm3)V=cvIHDxsrwr7(1^5{sPKEO#5Ea*+v6Em|&I)YgP0sxp%{QN|W"
    "Vr!EOH71$iCjQR=@a^DPL84;<0HN9&z_M{0ZW@sQKyw4d!x{h}ZlY+PreCQCfON*Wm)~IOvm5C!=sS+mMg;%}oJ9@*@Mab%(Jx6K"
    "*yJ17R2LOPf#j0a06;eb07EAFDN`UK0GtvBN%wDTs7%c6C@2BI<y9f)2w`w#iU&N;PXPeoNuY)RL>TgeTb(4>jhrj00>Cl_fU%AT"
    "a4#5uSrTv~DW9b(z$!^ZgZbAdoInzACJ<xK+#s3~m;rzy5B%Q4K}$vKh0+mL^K1BQkB={htjcAOSHmmhdnj@3K(VVRvylWow@gq<"
    "YaY|?Xl=yb*eCdyp~SO@Jg~WJDG4qBfSdwqOD~Tmp83ooEHpJ|7&cDr9Tw)vCdJ(U$c_M458`ad0Dymg(919*LOvV`WZ;3o7JvC;"
    "Mt;X_g0StpJ_0~BFn^N4=#<Cj=Y8dj>5ToA$anbTd@Ap*8USzv5MSR302nhH@J>quPP)0M`ghsSMF3=1%nKG3z3%i%9s!d6K|I=Z"
    "0vgdE)Wh+uMf*cA><*OI>vu=RGbR!KKXZpHN&gbfY00HM$_Efr;LGi2F7&ay9}NJyy}kVc0Px4lTTxU;S)Bpkda3mO1fuJ9xf~Un"
    "<90&ST9X45+uK8l5<5%PoAv;W9d!W-4l(_^MZIgbdC~>af(M|q0RQ4}P)%59JHg@Kn-E##<7_a~o8&{!t6mCXJIG(r?`>fWoO62;"
    "RZG~cra+7x{VqCOX{E0ahKNUi8!PdqfGPr%fVV4NNBH*f@lgN(@Zrag9}p@A6L7nw^w?}}Rrkx64j~UeHu{0IMF7AcsNHs#I3I2G"
    "^uFm4C@Ik!o`^TM5p)0ofEnHpo;Bc!;PChz0|4r?d?jbqtp^k(pc3$spCso}fb_WA%xglHY~!Zl0Y;7H27E1?L^N1_3}t!*5yts^"
    "@W-70C>;XUnz_JgKQJ)>u7u$j4{{aT73Ei^SC=UL+dO(91px2?y4|Y*)WU+uNDkJLfJ1;n3;_9ZJ$p1RBLMZwVpfJFbVNU)PZmD?"
    "g@Sh=fVsT>0*|NZARdnZ6dGXAH!?Cxoxx*x@oOmn_;^vc|Cj4LKaO?>zJJyBTp096!>wMPrO_@X|9zq6HvSf0J*U5*f;)9F-Q-$;"
    "f0+rG+ZDk1XproN3=-6LC#;4x92Vyj4y8G9P@Q%R;)ydwd38RYLxKvGHmIlhwZ*t83zZGym3(00j3L8jO`=tLw6IO`7%7P9QR;q%"
    "mlsT`U^?`1ARdM!-bR}6_?wZ}@X7$Pca4$&Se^KzudlC(EBMpZ>nlFud^Q`JvsbRE^G`-tenYwh*yS*e;}t>U91#FM0G=)q&Hi*q"
    "`RC!V4w{Bk4cz8^-Je?co1<Y+8^+Di!MCvG<?+^c>%|<i5797dtt`h|vn4q_+IjHHm@U4rL#q9+(JUh4eRv#%rS8_m7t%l#mMrzF"
    "IwSrp?hx#uNVKrp;^+q6{)k3%n}#jt82I#|@!6>!9mKZyZ7UWpPSW1u4)V1b#$_EB-}+=h)QjZoT&|d+Pu3Jq@`<WpVY-&_NlXs$"
    "Ln6FjFnH)eB;}Lj)#I+9v2bbfn@UpTc#`>vo>~wD7@G6f*SfuMR+jYui=$|1<ox)eKAg`!BlfjE$!TDpH1?|iU^fT=WRZ|G4})5("
    "buZTo(w-*t93A4=q1_Rn69?&#I6N@MBhkuJc0QiOJe1A=xeRFHq~m-=+gL!@gU3enH{B!1QnTV+)c;~Yc&Mh{{Sk@6VZOZ+P8|9o"
    "ky=NWZa|kHpn<&%rYM5DtS~u|ivIE~2ep3?(UfBrTgIRi5|4v=IjEHlx}0OD>nf!0Z2I3c8l&~aqB*n)uUEV?7^!N2Cu-6&<&|}#"
    "sl5Vy7E{Bt1qZ&(0eucy6{PbgZae?BAJKIH3ti9+#2@2d3=#m5{ce7$D8f%pUQd%X9!HpSiR+nkZ3O&n@@epbF1`(9pKIW7ou4=_"
    "K^$^dT|_TGmLE9#O!&w^IC^T~QYM>Wr4^wVF|@;&lmf-;j~@wIAW~J~#L6F2eR}u8g7+8>T8y5Y$RGb>=7DSAc}@Kgzg-l7b@R-8"
    "v^LXFM>kW;gqC0lTG0LI`bXDC;M0vdD{xn$T<V?T4!nz1h`34pwBkMR2jCw^wEaP!0ZOtf_oyN+J-0}>S{=Nq!FWpIcTqZYc1+*V"
    "a8P!&kR3BjS8hN<Y3aw5o{Z?JQ5v#gPsfYlP3SMHsH2x2kq;&RxNb$81^ob*&CT8R`a9@(c&iFDcs%Vhlmde2NsdCa10_rz>;&>}"
    "yT0e9?@hW?_J=~gM|h?3X0}?1zffT-Z44cA7@b<$+ds+Kw2-EzcQ0)0m+jX80DEZo5BmRaFyGHD!uR_y{%YknehXD}0{`&SeBbxq"
    "@~Pi+tz4c9p@`|pRV2L3&tE`a{2ei(ov0)E3+*3|s=s+96xW4%m2zKK^FQ);Lwr|pvHd#J;x^kVGwIfGv{FqM8dtyS_~czLTWhVg"
    "_D`AXy6(Z)=8&DV*Ri$M{=L=$Kx?hF0MJ@%t+fEqT5GMf0MJ@%t+fEqT5GMf0MJ@%t+fEqT5GMf0MJ@%t+fEqT5GMf0MJ@%t+fEq"
    "T5GNSSK9vpMj)nt8Dbd200000NkvXXu0mjf"
)

def build_display_material():
    """Pack TE's complete 66-indicator screen diagram as the live fallback."""
    png_data = base64.b85decode(_SCREEN_ART_B85.encode("ascii"))
    screen_path = os.path.join(tempfile.gettempdir(),
                               "halo_screen_indicators.png")
    with open(screen_path, "wb") as handle:
        handle.write(png_data)
    try:
        image = bpy.data.images.load(screen_path, check_existing=False)
        image.name = "halo_screen_indicators"
        image.colorspace_settings.name = 'sRGB'
        image.pack()
    finally:
        try: os.remove(screen_path)
        except OSError: pass
    if image.packed_file is None or tuple(image.size) != (1024, 289):
        raise RuntimeError("Exact EP-40 display texture failed to pack")

    screen = mat("m_display_live", (0.05, 0.35, 0.22), 0.40)
    nodes = screen.node_tree.nodes
    links = screen.node_tree.links
    bsdf = nodes.get("Principled BSDF")
    texture = nodes.new("ShaderNodeTexImage")
    texture.name = "halo_screen_texture"
    texture.image = image
    texture.extension = 'CLIP'
    links.new(texture.outputs["Color"], bsdf.inputs["Base Color"])
    links.new(texture.outputs["Color"], bsdf.inputs["Emission Color"])
    # Keep this at one so Blender exports the emissive connection to USD.
    bsdf.inputs["Emission Strength"].default_value = 1.0
    M['display'] = screen


def build_display_material_legacy():
    """Procedural emergency fallback retained for headless diagnostics."""
    width, height = 1024, 280
    pixels = array('f', [0.0]) * (width * height * 4)

    # sRGB palette measured from the supplied front-on product reference.
    bg_left = (0.204, 0.686, 0.533)
    bg_right = (0.090, 0.553, 0.384)
    dark = (0.051, 0.243, 0.173)
    ghost = (0.106, 0.471, 0.349)
    cream = (0.804, 1.000, 0.961)
    amber = (0.863, 0.592, 0.161)
    orange = (0.969, 0.353, 0.180)
    mint = (0.302, 0.749, 0.604)
    cyan = (0.314, 0.745, 0.816)
    blue = (0.255, 0.535, 0.790)

    def put(x, y, color):
        if not (0 <= x < width and 0 <= y < height):
            return
        # Blender image rows are bottom-up; drawing coordinates are top-down.
        idx = (((height - 1 - y) * width) + x) * 4
        pixels[idx] = color[0]
        pixels[idx + 1] = color[1]
        pixels[idx + 2] = color[2]
        pixels[idx + 3] = 1.0

    def background_at(x, y=0):
        t = max(0.0, min(1.0, x / (width - 1)))
        scan = 0.010 if (y // 4) % 2 == 0 else 0.0
        return tuple(min(1.0, bg_left[i] * (1.0 - t) + bg_right[i] * t + scan)
                     for i in range(3))

    for x in range(width):
        for y in range(height):
            put(x, y, background_at(x, y))

    def rect(x0, y0, x1, y1, color):
        xa, xb = sorted((int(x0), int(x1)))
        ya, yb = sorted((int(y0), int(y1)))
        for yy in range(ya, yb + 1):
            for xx in range(xa, xb + 1):
                put(xx, yy, color)

    def circle(cx, cy, radius, color, inner=0):
        rr, ii = radius * radius, inner * inner
        for yy in range(cy - radius, cy + radius + 1):
            for xx in range(cx - radius, cx + radius + 1):
                d2 = (xx - cx) ** 2 + (yy - cy) ** 2
                if ii <= d2 <= rr:
                    put(xx, yy, color)

    def line(x0, y0, x1, y1, thickness, color):
        dx, dy = x1 - x0, y1 - y0
        steps = max(abs(dx), abs(dy), 1)
        radius = max(1, thickness // 2)
        for step in range(steps + 1):
            t = step / steps
            circle(round(x0 + dx * t), round(y0 + dy * t), radius, color)

    def outline_rect(cx, cy, w, h, thickness, color):
        rect(cx - w // 2, cy - h // 2, cx + w // 2, cy - h // 2 + thickness, color)
        rect(cx - w // 2, cy + h // 2 - thickness, cx + w // 2, cy + h // 2, color)
        rect(cx - w // 2, cy - h // 2, cx - w // 2 + thickness, cy + h // 2, color)
        rect(cx + w // 2 - thickness, cy - h // 2, cx + w // 2, cy + h // 2, color)

    def play_triangle(cx, cy, radius, color):
        for yy in range(-radius, radius + 1):
            reach = max(0, int((yy + radius) * 0.55))
            rect(cx - radius // 2, cy + yy,
                 cx - radius // 2 + (radius - abs(yy)) + reach // 2,
                 cy + yy, color)

    def seven_digit(cx, cy, digit, lit_color, scale=1.0):
        segs = {
            0: "abcedf", 1: "bc", 2: "abged", 3: "abgcd", 4: "fgbc",
            5: "afgcd", 6: "afgecd", 7: "abc", 8: "abcdefg", 9: "abfgcd",
        }[digit]
        sw, sh, thick = int(35 * scale), int(72 * scale), max(4, int(7 * scale))
        half_w, half_h = sw // 2, sh // 2
        positions = {
            'a': (-half_w, -half_h, half_w, -half_h + thick),
            'g': (-half_w, -thick // 2, half_w, thick // 2),
            'd': (-half_w, half_h - thick, half_w, half_h),
            'f': (-half_w, -half_h, -half_w + thick, 0),
            'b': (half_w - thick, -half_h, half_w, 0),
            'e': (-half_w, 0, -half_w + thick, half_h),
            'c': (half_w - thick, 0, half_w, half_h),
        }
        for segment, bounds in positions.items():
            color = lit_color if segment in segs else ghost
            rect(cx + bounds[0], cy + bounds[1], cx + bounds[2], cy + bounds[3], color)

    def indicator(cx, cy, kind, variant):
        active = (orange, amber, mint, cyan, cream, blue)[variant % 6]
        color = active if variant % 5 in (0, 2) else dark
        r = 14 + (variant % 3)
        if kind == 0:  # sun / source burst
            circle(cx, cy, 6, color)
            for angle in range(0, 360, 45):
                a = math.radians(angle)
                line(cx + int(9 * math.cos(a)), cy + int(9 * math.sin(a)),
                     cx + int(r * math.cos(a)), cy + int(r * math.sin(a)), 4, color)
        elif kind == 1:  # outlined mode tile
            outline_rect(cx, cy, 25, 27, 5, color)
            if variant % 2: rect(cx + 3, cy + 3, cx + 10, cy + 10, active)
        elif kind == 2:  # drum / instrument
            rect(cx - 11, cy - 7, cx + 11, cy + 10, color)
            circle(cx, cy - 8, 11, active)
            rect(cx - 8, cy - 6, cx + 8, cy - 2, background_at(cx, cy))
        elif kind == 3:  # stacked dub bands
            for i in range(3 + variant % 2):
                rect(cx - 12 + i, cy - 13 + i * 9, cx + 12 - i, cy - 9 + i * 9, color)
        elif kind == 4:  # dial / clock
            circle(cx, cy, 14, color, inner=9)
            line(cx, cy, cx + (variant % 7) - 3, cy - 9, 4, active)
        elif kind == 5:  # waveform
            points = [(-14, 5), (-8, -9), (-2, 8), (5, -7), (14, 2)]
            for a, b in zip(points, points[1:]):
                line(cx + a[0], cy + a[1], cx + b[0], cy + b[1], 4, color)
        elif kind == 6:  # grid / sequencer
            for gy in range(3):
                for gx in range(3):
                    c = active if (gx + gy + variant) % 5 == 0 else color
                    rect(cx - 13 + gx * 10, cy - 13 + gy * 10,
                         cx - 7 + gx * 10, cy - 7 + gy * 10, c)
        elif kind == 7:  # speaker cone
            rect(cx - 13, cy - 6, cx - 7, cy + 6, color)
            line(cx - 7, cy - 6, cx + 5, cy - 13, 5, color)
            line(cx - 7, cy + 6, cx + 5, cy + 13, 5, color)
            circle(cx + 5, cy, 10, color, inner=7)
        elif kind == 8:  # record / play / loop state
            if variant % 3 == 0: circle(cx, cy, 13, orange)
            elif variant % 3 == 1: play_triangle(cx, cy, 14, cream)
            else:
                circle(cx, cy, 13, color, inner=9)
                line(cx + 8, cy - 8, cx + 14, cy - 2, 4, color)
        elif kind == 9:  # meter
            count = 3 + variant % 4
            for i in range(count):
                c = active if i >= count - 2 else color
                rect(cx - 13, cy + 11 - i * 7, cx + 13, cy + 15 - i * 7, c)
        elif kind == 10:  # X / process mark
            line(cx - 12, cy - 12, cx + 12, cy + 12, 5, color)
            line(cx + 12, cy - 12, cx - 12, cy + 12, 5, color)
        else:  # fan / quadrant state
            circle(cx, cy, 4, color)
            for angle in (25, 115, 205, 295):
                a = math.radians(angle + (variant % 3) * 8)
                line(cx + int(6 * math.cos(a)), cy + int(6 * math.sin(a)),
                     cx + int(16 * math.cos(a)), cy + int(16 * math.sin(a)), 6, active)

    # 66 fixed positions mirror the hardware's four-row density and status banks.
    icon_specs = []
    for row in range(4):
        for col in range(7):
            icon_specs.append((34 + col * 42, 38 + row * 55))
    icon_specs.extend(((352, 68), (414, 68), (476, 68)))
    icon_specs.extend((338 + col * 44, 164) for col in range(5))
    for row in range(4):
        for col in range(5):
            icon_specs.append((566 + col * 48, 38 + row * 55))
    for row in range(5):
        for col in range(2):
            icon_specs.append((856 + col * 78, 28 + row * 52))
    if len(icon_specs) != 66:
        raise RuntimeError(f"Display atlas must contain 66 indicators, got {len(icon_specs)}")

    # Draw every icon, then overwrite the measured central cells with 1·1·2.
    for index, (cx, cy) in enumerate(icon_specs):
        indicator(cx, cy, (index * 7 + index // 5) % 12, index)
    rect(323, 16, 505, 122, (0.106, 0.471, 0.349))
    for index, digit in enumerate((1, 1, 2)):
        cx = 352 + index * 62
        seven_digit(cx, 68, digit, cream, scale=1.0)
        if index < 2: circle(cx + 24, 105, 5, dark)

    block_font = {
        'A':("01110","10001","10001","11111","10001","10001","10001"),
        'D':("11110","10001","10001","10001","10001","10001","11110"),
        'E':("11111","10000","10000","11110","10000","10000","11111"),
        'I':("11111","00100","00100","00100","00100","00100","11111"),
        'M':("10001","11011","10101","10101","10001","10001","10001"),
        'N':("10001","11001","10101","10011","10001","10001","10001"),
        'O':("01110","10001","10001","10001","10001","10001","01110"),
        'P':("11110","10001","10001","11110","10000","10000","10000"),
        'R':("11110","10001","10001","11110","10100","10010","10001"),
        'S':("01111","10000","10000","01110","00001","00001","11110"),
        'T':("11111","00100","00100","00100","00100","00100","00100"),
        'U':("10001","10001","10001","10001","10001","10001","01110"),
        'Y':("10001","10001","01010","00100","00100","00100","00100"),
    }

    def block_text(text, x, y, scale, color):
        cursor = x
        for character in text:
            glyph = block_font[character]
            for row, bits in enumerate(glyph):
                for col, bit in enumerate(bits):
                    if bit == '1':
                        rect(cursor + col * scale, y + row * scale,
                             cursor + (col + 1) * scale - 1,
                             y + (row + 1) * scale - 1, color)
            cursor += 6 * scale
        return cursor

    cursor = 126
    for word, color in (("SOUND", dark), ("MAIN", amber), ("TEMPO", dark),
                        ("ERASE", cream), ("SYSTEM", dark)):
        cursor = block_text(word, cursor, 246, 3, color) + 19

    image = bpy.data.images.new("halo_screen_indicators", width=width, height=height,
                                alpha=False, float_buffer=False)
    image.colorspace_settings.name = 'sRGB'
    image.pixels.foreach_set(pixels)
    image.update()
    image.file_format = 'PNG'
    image.pack()
    if image.packed_file is None:
        raise RuntimeError("Display image must be packed for USDZ export")

    screen = mat("m_display_live", (0.05, 0.35, 0.22), 0.40)
    nodes = screen.node_tree.nodes
    links = screen.node_tree.links
    bsdf = nodes.get("Principled BSDF")
    texture = nodes.new("ShaderNodeTexImage")
    texture.name = "halo_screen_texture"
    texture.image = image
    texture.extension = 'CLIP'
    links.new(texture.outputs["Color"], bsdf.inputs["Base Color"])
    links.new(texture.outputs["Color"], bsdf.inputs["Emission Color"])
    bsdf.inputs["Emission Strength"].default_value = 1.0
    M['display'] = screen

# ---------------------------------------------------------------- primitives
OBJS = []

def _finish(o, name, mat_key, bevel):
    o.name = name
    if o.data and hasattr(o.data, "materials"):
        o.data.materials.append(M[mat_key])
    if bevel and bevel > 0:
        md = o.modifiers.new("bevel", 'BEVEL')
        md.width = bevel; md.segments = 3; md.limit_method = 'ANGLE'
    for p in o.data.polygons: p.use_smooth = False
    OBJS.append(o)
    return o

def parent_keep_world(child, parent):
    """Parent decorative face work so it follows animated caps/knobs."""
    world = child.matrix_world.copy()
    child.parent = parent
    child.matrix_world = world
    return child

def box(name, w, d, h, uu, vv, z, mat_key, bevel=0.0010, angle=0.0):
    bpy.ops.mesh.primitive_cube_add(size=1.0, location=(u(uu), v(vv), z))
    o = bpy.context.active_object
    o.dimensions = (w, d, h)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    if angle:
        o.rotation_euler[2] = angle
    return _finish(o, name, mat_key, bevel)

def disc(name, r, h, uu, vv, z, mat_key, bevel=0.0006, verts=64):
    bpy.ops.mesh.primitive_cylinder_add(radius=r, depth=h, vertices=verts,
                                         location=(u(uu), v(vv), z))
    o = _finish(bpy.context.active_object, name, mat_key, bevel)
    for poly in o.data.polygons:
        poly.use_smooth = len(poly.vertices) == 4
    return o

def cylinder_y(name, r, depth, uu, y, z, mat_key, verts=48):
    bpy.ops.mesh.primitive_cylinder_add(
        radius=r, depth=depth, vertices=verts,
        location=(u(uu), y, z), rotation=(math.pi / 2.0, 0.0, 0.0),
    )
    o = _finish(bpy.context.active_object, name, mat_key, 0.00025)
    for poly in o.data.polygons:
        poly.use_smooth = len(poly.vertices) == 4
    return o

def annulus(name, outer_rx, outer_ry, inner_rx, inner_ry, h, z, mat_key, segments=128):
    """Elliptical ring mesh; unlike a disc it never reads as a platter."""
    verts = []
    for zz in (z + h / 2.0, z - h / 2.0):
        for rx, ry in ((outer_rx, outer_ry), (inner_rx, inner_ry)):
            for i in range(segments):
                a = math.tau * i / segments
                verts.append((rx * math.cos(a), ry * math.sin(a), zz))
    ot, it, ob, ib = 0, segments, segments * 2, segments * 3
    faces = []
    for i in range(segments):
        j = (i + 1) % segments
        faces.extend([
            (ot+i, ot+j, it+j, it+i),
            (ob+i, ib+i, ib+j, ob+j),
            (ot+i, ob+i, ob+j, ot+j),
            (it+i, it+j, ib+j, ib+i),
        ])
    mesh = bpy.data.meshes.new(name + "_mesh")
    mesh.from_pydata(verts, [], faces)
    mesh.update()
    o = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(o)
    return _finish(o, name, mat_key, 0)

def display_plane(name, w, d, uu, vv, z, mat_key):
    """Single top-facing live surface with a predictable full-frame UV set."""
    cx, cy = u(uu), v(vv)
    verts = (
        (cx - w / 2.0, cy - d / 2.0, z),
        (cx + w / 2.0, cy - d / 2.0, z),
        (cx + w / 2.0, cy + d / 2.0, z),
        (cx - w / 2.0, cy + d / 2.0, z),
    )
    mesh = bpy.data.meshes.new(name + "_mesh")
    mesh.from_pydata(verts, [], ((0, 1, 2, 3),))
    mesh.update()
    uv = mesh.uv_layers.new(name="UVMap")
    for loop_index, coords in zip(mesh.polygons[0].loop_indices,
                                  ((0, 0), (1, 0), (1, 1), (0, 1))):
        uv.data[loop_index].uv = coords
    o = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(o)
    return _finish(o, name, mat_key, 0)

def capsule(name, length, thickness, h, x_m, y_m, z, mat_key,
            angle=0.0, parent=None):
    """Flat rounded stroke used to construct the measured RIDDIM lettering."""
    core_length = max(length - thickness, 0.0001)
    pieces = [box(name + "_bar", core_length, thickness, h,
                  0.5 + x_m / W, 0.5 + y_m / D, z,
                  mat_key, bevel=0.00015, angle=angle)]
    half = core_length / 2.0
    for index, direction in enumerate((-1.0, 1.0)):
        ex = x_m + direction * half * math.cos(angle)
        ey = y_m + direction * half * math.sin(angle)
        pieces.append(disc(f"{name}_cap_{index}", thickness / 2.0, h,
                           0.5 + ex / W, 0.5 + ey / D, z,
                           mat_key, bevel=0.0001, verts=32))
    if parent is not None:
        for piece in pieces:
            parent_keep_world(piece, parent)
    return pieces

# Flat text legend (neutral face — NOT TE's proprietary font/branding). Created as
# a text object then converted to a flat mesh so it stays crisp and exports to USD.
_legend_n = 0
def legend(content, uu, vv, z, size, mat_key, parent=None):
    global _legend_n
    if size < MIN_LEGEND_SIZE:
        raise ValueError(f"Legend '{content}' is below the 2.1 mm RealityKit floor")
    bpy.ops.object.select_all(action='DESELECT')
    bpy.ops.object.text_add(location=(u(uu), v(vv), z))
    o = bpy.context.active_object
    o.data.body = content
    o.data.size = size
    o.data.align_x = 'CENTER'
    o.data.align_y = 'CENTER'
    o.data.offset = 0.0
    bpy.context.view_layer.objects.active = o
    o.select_set(True)
    bpy.ops.object.convert(target='MESH')
    o = bpy.context.active_object
    _legend_n += 1
    o.name = f"legend_{_legend_n}"
    if o.data.materials: o.data.materials.clear()
    o.data.materials.append(M[mat_key])
    OBJS.append(o)
    if parent is not None:
        parent_keep_world(o, parent)
    return o

def keycap(name, w, d, h, uu, vv, mat_key, bevel=0.00115):
    """Raised face over a dark well: clearer silhouette and visible press travel."""
    box(name + "_well", w + 0.0016, d + 0.0016, 0.0012,
        uu, vv, CONTROL_BASE + 0.0005, 'dark', bevel=0.00075)
    return box(name, w, d, h, uu, vv, CONTROL_BASE + 0.00055 + h / 2.0,
               mat_key, bevel=bevel)

def pad_digit(name, digit, uu, vv, parent):
    """Rounded modular pad numeral, replacing Blender's generic text face."""
    z = CONTROL_BASE + 0.00635
    if digit == 1:
        stroke = box(name + "_digit_stem", 0.0024, 0.0118, 0.00062,
                     uu, vv, z, 'legendG', bevel=0.00028)
        parent_keep_world(stroke, parent)
        return
    if digit == 7:
        top = box(name + "_digit_top", 0.0085, 0.0022, 0.00062,
                  uu, vv + 0.0051 / D, z, 'legendG', bevel=0.00028)
        diagonal = box(name + "_digit_diag", 0.0106, 0.0022, 0.00062,
                       uu + 0.0005 / W, vv - 0.0003 / D, z,
                       'legendG', bevel=0.00028, angle=1.10)
        parent_keep_world(top, parent)
        parent_keep_world(diagonal, parent)
        return

    patterns = {
        0: "abcedf", 2: "abged", 3: "abgcd", 4: "fgbc",
        5: "afgcd", 6: "afgecd", 8: "abcdefg", 9: "abfgcd",
    }
    segment_positions = {
        'a': (0.0,  0.0051, 0.0084, 0.0022),
        'g': (0.0,  0.0000, 0.0084, 0.0022),
        'd': (0.0, -0.0051, 0.0084, 0.0022),
        'f': (-0.0037,  0.00255, 0.0022, 0.0046),
        'b': ( 0.0037,  0.00255, 0.0022, 0.0046),
        'e': (-0.0037, -0.00255, 0.0022, 0.0046),
        'c': ( 0.0037, -0.00255, 0.0022, 0.0046),
    }
    for segment in patterns[digit]:
        dx, dy, sw, sd = segment_positions[segment]
        piece = box(f"{name}_digit_{segment}", sw, sd, 0.00062,
                    uu + dx / W, vv + dy / D, z,
                    'legendG', bevel=0.00028)
        parent_keep_world(piece, parent)

def build_riddim_branding(panel):
    """Measured private-build reproduction of TE's printed RIDDIM lettering."""
    total_w, letter_h = 0.0373, 0.0122
    stroke, gap = 0.00115, 0.0012
    center_x, center_y = u(0.152), v(0.894)
    left = center_x - total_w / 2.0
    # Ink sits essentially flush on the 1 mm branding panel rather than reading
    # as raised applique.  A 0.09 mm lift prevents z-fighting in RealityKit.
    z = TOP_FACE + 0.00110
    ink_h = 0.00010

    def square_bar(name, width, depth, x, y, angle=0.0, material='brandG'):
        piece = box("riddim_" + name, width, depth, ink_h,
                    0.5 + x / W, 0.5 + y / D, z,
                    material, bevel=0.00008, angle=angle)
        parent_keep_world(piece, panel)
        return piece

    def round_bar(name, length, thickness, x, y, angle=0.0,
                  material='brandG', zz=None):
        return capsule("riddim_" + name, length, thickness, ink_h,
                       x, y, z if zz is None else zz,
                       material, angle=angle, parent=panel)

    def dot(name, radius, x, y, material='brandG', zz=z):
        piece = disc("riddim_" + name, radius, ink_h,
                     0.5 + x / W, 0.5 + y / D, zz,
                     material, bevel=0.00004, verts=48)
        parent_keep_world(piece, panel)
        return piece

    # Width ratios and tracking are taken from the official straight-on device
    # image.  In particular, the narrow I forms and wide lowercase m are part of
    # the wordmark's identity and should not be normalized to a generic font.
    widths = (0.0060, 0.0011, 0.0060, 0.0061, 0.0012, 0.0108)
    starts = []
    cursor = left
    for width in widths:
        starts.append(cursor)
        cursor += width + gap

    # R — square monoline joins, rounded outer bowl and a nearly vertical leg.
    x0, lw = starts[0], widths[0]
    square_bar("r_stem", stroke, letter_h, x0 + stroke / 2.0, center_y)
    square_bar("r_top", lw - stroke, stroke, x0 + (lw + stroke) / 2.0,
               center_y + letter_h / 2.0 - stroke / 2.0)
    square_bar("r_mid", lw - stroke, stroke, x0 + (lw + stroke) / 2.0,
               center_y + 0.00025)
    round_bar("r_bowl", letter_h / 2.0 - stroke, stroke,
              x0 + lw - stroke / 2.0, center_y + letter_h / 4.0,
              math.pi / 2.0)
    round_bar("r_leg", 0.0064, stroke, x0 + lw * 0.64,
              center_y - letter_h * 0.25, -1.35)

    # Narrow monoline I.
    square_bar("i1", widths[1], letter_h,
               starts[1] + widths[1] / 2.0, center_y)

    # Filled D silhouettes with small face-colour counters match the printed
    # glyph better than monoline outlines at the normal in-app camera distance.
    for index in (2, 3):
        x0, lw = starts[index], widths[index]
        square_bar(f"d{index}_stem", stroke, letter_h,
                   x0 + stroke / 2.0, center_y)
        round_bar(f"d{index}_body", letter_h, lw - stroke,
                  x0 + (lw + stroke) / 2.0, center_y, math.pi / 2.0)
        # Counter is a narrow vertical pill, printed in the panel colour.
        counter_w = max(0.0010, lw - 2.0 * stroke)
        round_bar(f"d{index}_counter", letter_h - 2.0 * stroke,
                  counter_w, x0 + stroke + counter_w / 2.0,
                  center_y, math.pi / 2.0, material='brand',
                  zz=z + 0.000015)

    square_bar("i2", widths[4], letter_h,
               starts[4] + widths[4] / 2.0, center_y)

    # Final lowercase m: three descending stems and two true rounded shoulders.
    x0, lw = starts[5], widths[5]
    stem_xs = (x0 + stroke / 2.0, x0 + lw / 2.0,
               x0 + lw - stroke / 2.0)
    shoulder_span = stem_xs[1] - stem_xs[0]
    shoulder_r = shoulder_span / 2.0
    shoulder_y = center_y + letter_h / 2.0 - shoulder_r
    for index, xx in enumerate(stem_xs):
        stem_h = letter_h / 2.0 + shoulder_r
        square_bar(f"m_stem_{index}", stroke, stem_h, xx,
                   center_y - letter_h / 2.0 + stem_h / 2.0)
    for index, cx in enumerate(((stem_xs[0] + stem_xs[1]) / 2.0,
                                (stem_xs[1] + stem_xs[2]) / 2.0)):
        dot(f"m_shoulder_outer_{index}", shoulder_r, cx, shoulder_y)
        dot(f"m_shoulder_inner_{index}", max(0.0001, shoulder_r - stroke),
            cx, shoulder_y, material='brand', zz=z + 0.000015)
        # Hide the lower half of each ring; the three verticals supply the legs.
        mask = box(f"riddim_m_shoulder_mask_{index}",
                   max(0.0001, shoulder_span - stroke),
                   shoulder_r + 0.00010, ink_h,
                   0.5 + cx / W,
                   0.5 + (shoulder_y - shoulder_r / 2.0) / D,
                   z + 0.000020, 'brand', bevel=0.0)
        parent_keep_world(mask, panel)

    legend("SUPERTONE", 0.123, 0.847, z + 0.00005,
           0.0058, 'brandO', parent=panel)
    legend("ORIGINAL LAYERING MACHINE", 0.239, 0.772, z + 0.00005,
           0.0048, 'brandI', parent=panel)

# ---------------------------------------------------------------- chassis
def build_chassis():
    # Tight bevels retain the real 176 x 240 x 16 mm silhouette. The previous
    # bevel radii were larger than several pieces and visibly inflated the case.
    box("chassis_base", W, D, TH, 0.5, 0.5, 0.0, 'body', bevel=0.0022)
    box("chassis_topPlate", W - 0.0020, D - 0.0020, 0.0014,
        0.5, 0.5, TOP + 0.0007, 'plate', bevel=0.00075)
    box("chassis_edgeBand", W + 0.0004, D + 0.0004, 0.0026,
        0.5, 0.5, -TH / 2.0 + 0.0015, 'edge', bevel=0.0008)

# ---------------------------------------------------------------- upper panel
def build_upper():
    # Pixel-measured against the supplied 450 px straight-on reference, scaled
    # to the known 176 mm chassis width.
    panel = box("brand_panel", 0.118, 0.047, 0.0010,
                0.334, 0.856, TOP_FACE + 0.00055, 'brand', bevel=0.00035)
    build_riddim_branding(panel)

    # One UV-mapped contract plane carries the complete default icon atlas. Halo's
    # live renderer can later replace this one material without fighting a cube UV.
    box("display_bezel", 0.174, 0.0497, 0.0014,
        0.500, 0.656, TOP_FACE + 0.00048, 'dark', bevel=0.00065)
    display_plane("display_surface", 0.170, 0.0454,
                  0.498, 0.656, TOP_FACE + 0.00125, 'display')

    # Speaker: a 43 mm dark opening under a full rectangular set of raised slats.
    # Parenting the visible grille work to the contract entity makes app-driven
    # audio breathing animate the whole assembly rather than a buried disc.
    spk_u, spk_v, spk_r = 0.847, 0.844, 0.0214
    box("speaker_panel", 0.057, 0.047, 0.0010,
        0.837, 0.844, TOP_FACE + 0.00055, 'brand', bevel=0.00035)
    grille = disc("speaker_grille", spk_r, 0.0012,
                  spk_u, spk_v, TOP_FACE + 0.00125, 'dark', bevel=0.00035)
    pitch = 0.00425
    for i in range(11):
        dy = (i - 5) * pitch
        slat = box(f"speaker_slat_{i}", 0.056, 0.00225, 0.00085,
                   0.837, spk_v + dy / D, TOP_FACE + 0.00210,
                   'plate', bevel=0.00035)
        parent_keep_world(slat, grille)

    # Built-in microphone beneath the left edge of the speaker grille.
    disc("mic_port", 0.0015, 0.0008,
         0.745, 0.775, TOP_FACE + 0.00225, 'ink', bevel=0.00015)

# ---------------------------------------------------------------- knobs + fader
def build_knobs_fader():
    knobs = [
        # name, u, v, skirt material, crown material, outer radius, crown radius
        ("knob_volume", 0.097, 0.494, 'edge',   'cap',     0.0089,  0.00675),
        ("knob_x",      0.773, 0.492, 'orange', 'orangeC', 0.0097,  0.00650),
        ("knob_y",      0.910, 0.492, 'green',  'greenC',  0.00945, 0.00650),
    ]
    for name, uu, vv, skirt_mk, crown_mk, radius, crown_radius in knobs:
        # Shallow full-width skirt + smaller crown: a 6.8 mm stepped profile,
        # replacing the old visually heavy 9.5 mm monolithic cylinder.
        k = disc(name, radius, 0.0022, uu, vv,
                 TOP_FACE + 0.0011, skirt_mk, bevel=0.00055)
        crown = disc(name + "_crown", crown_radius, 0.0046, uu, vv,
                     TOP_FACE + 0.0045, crown_mk, bevel=0.00075)
        parent_keep_world(crown, k)
        indicator = box(name + "_indicator", 0.0022, 0.0034, 0.00050,
                        uu, vv + 0.0024 / D, TOP_FACE + 0.00708,
                        'brandI' if name == 'knob_volume' else 'legendL',
                        bevel=0.00020)
        parent_keep_world(indicator, k)

    # Slim 35 mm travel and 12 mm cap match the reference's left-hand fader.
    box("fader_track", 0.0030, 0.035, 0.0014,
        0.094, 0.216, TOP_FACE + 0.0008, 'dark', bevel=0.00065)
    box("fader_cap", 0.012, 0.0095, 0.0050,
        0.094, 0.206, TOP_FACE + 0.0030, 'cap', bevel=0.0010)

# ---------------------------------------------------------------- buttons
def build_buttons():
    bw, bd, bh = 0.0167, 0.0096, 0.0040
    lower_d = 0.0075

    def make_button(name, uu, vv, mk, text, text_mat='legendG', text_size=0.0024,
                    secondary=None, secondary_mat='legendO', secondary_mk='cap'):
        cap = keycap(name, bw, bd, bh, uu, vv, mk, bevel=0.00105)
        legend(text, uu, vv, CONTROL_BASE + 0.00055 + bh + 0.00022,
               text_size, text_mat, parent=cap)
        if secondary:
            lower_v = vv - 0.038
            lower = keycap(name + "_secondary", bw, lower_d, 0.0030,
                           uu, lower_v, secondary_mk, bevel=0.00085)
            legend(secondary, uu, lower_v,
                   CONTROL_BASE + 0.00055 + 0.0030 + 0.00022,
                   MIN_LEGEND_SIZE, secondary_mat, parent=lower)
        return cap

    # Exact centers measured from the front-on reference. Secondary functions
    # are physically separate lower tiles, not text squeezed onto the main cap.
    make_button("button_sound", 0.229, 0.510, 'cap', "SOUND",
                secondary="EDIT", secondary_mk='brand')
    make_button("button_main", 0.367, 0.510, 'cap', "MAIN",
                secondary="COMMIT", secondary_mat='legendL', secondary_mk='orange')
    make_button("button_tempo", 0.505, 0.510, 'cap', "TEMPO",
                secondary="LOOP", secondary_mat='legendL', secondary_mk='green')

    make_button("button_keys", 0.094, 0.411, 'cap', "KEYS", text_size=0.0027)
    make_button("button_sample", 0.771, 0.411, 'orange', "SAMPLE",
                text_mat='legendL', text_size=0.0021,
                secondary="CHOP", secondary_mat='legendL', secondary_mk='orange')
    make_button("button_timing", 0.910, 0.411, 'green', "TIMING",
                text_mat='legendL', text_size=0.0021,
                secondary="CORRECT", secondary_mat='legendL', secondary_mk='green')

    # Left utility button above the fader.
    make_button("fader_mode_button", 0.094, 0.345, 'cap', "FADER", text_size=0.0022)
    make_button("button_fx", 0.771, 0.310, 'cap', "FX", text_size=0.0028,
                secondary="OUTPUT", secondary_mk='brand')
    make_button("button_erase", 0.910, 0.310, 'cap', "ERASE", text_size=0.0023,
                secondary="SYSTEM", secondary_mk='brand')

    # +/- are square performance pads in the reference.
    for name, uu, text in (
        ("button_minus", RIGHT_COLS[0], "−"),
        ("button_plus", RIGHT_COLS[1], "+"),
    ):
        cap = keycap(name, PAD_SIZE, PAD_SIZE, 0.0055,
                     uu, 0.196, 'cap', bevel=0.00125)
        legend(text, uu, 0.196, CONTROL_BASE + 0.00628,
               0.0060, 'legendG', parent=cap)

    make_button("button_shift", 0.094, 0.097, 'cap', "SHIFT", text_size=0.0023)

    for name, uu, mk, text, lm, ls in (
        ("button_record", RIGHT_COLS[0], 'orange', "RECORD", 'legendL', 0.0021),
        ("button_play", RIGHT_COLS[1], 'green', "PLAY", 'legendL', 0.0027),
    ):
        cap = keycap(name, PAD_SIZE, PAD_SIZE, 0.0055,
                     uu, 0.098, mk, bevel=0.00125)
        legend(text, uu, 0.098, CONTROL_BASE + 0.00628,
               ls, lm, parent=cap)

# ---------------------------------------------------------------- pad matrix
def build_pads():
    grid = (
        ("pad_7", "pad_8", "pad_9"),
        ("pad_4", "pad_5", "pad_6"),
        ("pad_1", "pad_2", "pad_3"),
        ("pad_dot", "pad_0", "pad_enter"),
    )
    for row_index, row in enumerate(grid):
        for col_index, name in enumerate(row):
            cap = keycap(name, PAD_SIZE, PAD_SIZE, 0.0055,
                         GRID_COLS[col_index], GRID_ROWS[row_index],
                         'cap', bevel=0.00125)
            if name not in ("pad_dot", "pad_enter"):
                pad_digit(name, int(name.removeprefix("pad_")),
                          GRID_COLS[col_index], GRID_ROWS[row_index], cap)

    # The four left pads are instrument selectors, not A/B/C/D-labelled keys.
    # Their original, vector-like glyphs use only robust >= 2.1 mm features.
    for row_index, name in enumerate(("group_a", "group_b", "group_c", "group_d")):
        keycap(name, PAD_SIZE, PAD_SIZE, 0.0055,
               GROUP_U, GRID_ROWS[row_index], 'cap', bevel=0.00125)

    glyph_z = CONTROL_BASE + 0.00635

    # A — drum: green shell and orange head.
    cap = bpy.data.objects["group_a"]
    parent_keep_world(box("glyph_drum_shell", 0.0100, 0.0070, 0.00065,
                          GROUP_U, GRID_ROWS[0] - 0.0007 / D, glyph_z,
                          'green', bevel=0.0010), cap)
    parent_keep_world(box("glyph_drum_head", 0.0100, 0.0025, 0.00072,
                          GROUP_U, GRID_ROWS[0] + 0.0038 / D, glyph_z + 0.00005,
                          'orange', bevel=0.0008), cap)

    # B — bass: diagonal neck with three orange frets.
    cap = bpy.data.objects["group_b"]
    parent_keep_world(box("glyph_bass_neck", 0.0110, 0.0034, 0.00068,
                          GROUP_U, GRID_ROWS[1], glyph_z,
                          'green', bevel=0.0010, angle=-0.48), cap)
    for i, dx in enumerate((-0.0032, 0.0, 0.0032)):
        parent_keep_world(disc(f"glyph_bass_fret_{i}", 0.00125, 0.00076,
                               GROUP_U + dx / W, GRID_ROWS[1] + 0.0020 / D,
                               glyph_z + 0.00006, 'orange', bevel=0.00015,
                               verts=32), cap)

    # C — four offset key bars, alternating the palette.
    cap = bpy.data.objects["group_c"]
    for i, (dx, mk) in enumerate((
        (-0.0042, 'orange'), (-0.0014, 'orange'),
        ( 0.0014, 'green'),  ( 0.0042, 'green'),
    )):
        parent_keep_world(box(f"glyph_keys_{i}", 0.0025, 0.0085, 0.00068,
                              GROUP_U + dx / W, GRID_ROWS[2], glyph_z,
                              mk, bevel=0.00045), cap)

    # D — orange record/sample disc with two cream holes.
    cap = bpy.data.objects["group_d"]
    parent_keep_world(disc("glyph_disc", 0.0051, 0.00070,
                           GROUP_U, GRID_ROWS[3], glyph_z,
                           'orange', bevel=0.00025), cap)
    for i, dx in enumerate((-0.0020, 0.0020)):
        parent_keep_world(disc(f"glyph_disc_hole_{i}", 0.00125, 0.00078,
                               GROUP_U + dx / W, GRID_ROWS[3], glyph_z + 0.00008,
                               'legendL', bevel=0.00012, verts=32), cap)

    # Dot/sample pad uses the small orange square visible on the hardware.
    cap = bpy.data.objects["pad_dot"]
    parent_keep_world(box("pad_dot_mark", 0.0050, 0.0050, 0.00070,
                          GRID_COLS[0] - 0.0040 / W,
                          GRID_ROWS[3] + 0.0040 / D,
                          glyph_z, 'orange', bevel=0.00075), cap)

    # Recessed status lamps occupy the measured inter-row gaps.
    for row_index, vv in enumerate(GRID_ROWS[:-1]):
        lamp_v = vv - 0.052
        for col_index, uu in enumerate((GROUP_U,) + GRID_COLS):
            mk = 'orange' if (row_index + col_index) % 3 == 1 else 'ink'
            disc(f"status_lamp_{row_index}_{col_index}", 0.00125, 0.00065,
                 uu, lamp_v, TOP_FACE + 0.00165, mk,
                 bevel=0.00015, verts=32)

# ---------------------------------------------------------------- ports + halo
def build_legends():
    pad_z = CONTROL_BASE + 0.00628
    legend("ENTER", GRID_COLS[2], GRID_ROWS[3], pad_z,
           MIN_LEGEND_SIZE, 'legendO', parent=bpy.data.objects["pad_enter"])

    # Functional plate legends use Blender's neutral font; no protected marks.
    plate_z = TOP_FACE + 0.00165
    legend("VOLUME", 0.094, 0.548, plate_z, 0.0022, 'legendG')
    legend("DUB", 0.771, 0.548, plate_z, 0.0022, 'legendG')
    legend("METRONOME", 0.910, 0.548, plate_z, MIN_LEGEND_SIZE, 'legendG')
    legend("X", 0.771, 0.443, plate_z, 0.0060, 'legendO')
    legend("Y", 0.910, 0.443, plate_z, 0.0060, 'legendG')

def build_ports_halo():
    # Four TRS sockets plus USB-C and power occupy the far/top edge. The shallow
    # labelled tabs are visible in the app's hero angle; edge recesses add depth.
    box("ports_strip", W - 0.014, 0.0060, 0.0060,
        0.500, 0.998, 0.0010, 'edge', bevel=0.00065)

    tab_z = TOP_FACE + 0.00135
    label_z = TOP_FACE + 0.00278
    tabs = (
        ("port_output_tab", 0.093, 0.028, 'cap',    "OUT",   'legendG'),
        ("port_input_tab",  0.245, 0.027, 'orange', "IN",    'legendL'),
        ("port_sync_tab",   0.382, 0.030, 'green',  "SYNC",  'legendL'),
        ("port_midi_tab",   0.515, 0.030, 'green',  "MIDI",  'legendL'),
        ("port_usb_tab",    0.714, 0.036, 'cap',    "USB",   'legendG'),
        ("port_power_tab",  0.895, 0.035, 'cap',    "POWER", 'legendG'),
    )
    for name, uu, width, mk, text, lm in tabs:
        tab = box(name, width, 0.010, 0.0024,
                  uu, 0.982, tab_z, mk, bevel=0.00055)
        legend(text, uu, 0.982, label_z, MIN_LEGEND_SIZE, lm, parent=tab)

    far_y = D / 2.0 + 0.0010
    for name, uu in (
        ("port_output_socket", 0.093),
        ("port_input_socket", 0.245),
        ("port_sync_socket", 0.382),
        ("port_midi_socket", 0.515),
    ):
        cylinder_y(name, 0.0032, 0.0060, uu, far_y, 0.0005, 'dark')

    box("ports_usb", 0.0115, 0.0060, 0.0042,
        0.714, 1.004, 0.0010, 'dark', bevel=0.00105)
    box("port_power_switch", 0.0130, 0.0060, 0.0045,
        0.895, 1.004, 0.0010, 'dark', bevel=0.00075)

    # A narrow ellipse follows the portrait chassis perimeter. The old solid
    # 216 mm disc looked like a turntable platter and obscured the instrument.
    annulus("halo_ring", 0.0935, 0.1255, 0.0912, 0.1232,
            0.0008, -TH / 2.0 - 0.0010, 'ink')


REQUIRED_OBJECTS = {
    "chassis_base", "chassis_topPlate", "chassis_edgeBand",
    "display_surface", "speaker_grille", "halo_ring", "mic_port",
    "group_a", "group_b", "group_c", "group_d",
    "pad_dot", "pad_0", "pad_1", "pad_2", "pad_3", "pad_4",
    "pad_5", "pad_6", "pad_7", "pad_8", "pad_9", "pad_enter",
    "knob_volume", "knob_x", "knob_y", "fader_track", "fader_cap",
    "button_sound", "button_main", "button_tempo", "button_sample",
    "button_keys", "button_timing", "button_fx", "button_erase",
    "button_shift", "button_minus", "button_plus", "button_record",
    "button_play", "ports_strip", "ports_usb",
}

def validate_contract():
    names = [obj.name for obj in bpy.data.objects]
    missing = sorted(REQUIRED_OBJECTS - set(names))
    duplicates = sorted(name for name in REQUIRED_OBJECTS if names.count(name) != 1)
    if missing or duplicates:
        raise RuntimeError(f"EP40 contract invalid; missing={missing}, duplicates={duplicates}")
    if "ep40_root" in names:
        raise RuntimeError("ep40_root must be supplied once by root_prim_path, not nested as an object")
    dims = bpy.data.objects["chassis_base"].dimensions
    if any(abs(actual - expected) > 1e-6 for actual, expected in zip(dims, (W, D, TH))):
        raise RuntimeError(f"Chassis dimensions changed: {tuple(dims)}")
    if bpy.context.scene.world is not None:
        raise RuntimeError("Scene world must remain None for RealityKit-owned lighting")
    surface = bpy.data.objects["display_surface"]
    if len(surface.data.polygons) != 1 or len(surface.data.uv_layers) != 1:
        raise RuntimeError("display_surface must remain one quad with one full-frame UV set")
    screen = bpy.data.images.get("halo_screen_indicators")
    if screen is None or tuple(screen.size) != (1024, 289) or screen.packed_file is None:
        raise RuntimeError("The exact packed 66-indicator display atlas is missing")

# ---------------------------------------------------------------- assemble
def build():
    reset(); build_materials(); build_display_material()
    build_chassis(); build_upper(); build_knobs_fader()
    build_buttons(); build_pads(); build_legends(); build_ports_halo()
    validate_contract()

def export(path):
    bpy.context.scene.world = None
    bpy.ops.wm.usd_export(
        filepath=path, selected_objects_only=False, export_materials=True,
        convert_orientation=True, export_global_up_selection='Y',
        export_global_forward_selection='NEGATIVE_Z', meters_per_unit=1.0,
        root_prim_path="/ep40_root", author_blender_name=False,
    )
    with zipfile.ZipFile(path) as archive:
        if archive.testzip() is not None:
            raise RuntimeError("USDZ archive failed CRC validation")
        if not any(member.endswith("/halo_screen_indicators.png")
                   for member in archive.namelist()):
            raise RuntimeError("USDZ export omitted the packed display texture")
    print("EP40_EXPORT_OK", path)

if __name__ == "__main__":
    build()
    export(sys.argv[-1])
