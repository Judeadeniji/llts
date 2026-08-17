; ModuleID = 'examples/test-llvm-new-features.lls'
source_filename = "examples/test-llvm-new-features.lls"
target triple = "x86_64-unknown-linux-gnu"

@msg = global [2 x i8] zeroinitializer
@result = global double 0.000000e+00
@arr = global [3 x i64] zeroinitializer
@maybe = global i64 0
@sz = global i64 0
@exp = global double 0.000000e+00
@usz = global i64 0
@base = global double 0.000000e+00
@fmt = private unnamed_addr constant [6 x i8] c"%lld \00", align 1
@nl = private unnamed_addr constant [2 x i8] c"\0A\00", align 1
@.str = private unnamed_addr constant [3 x i8] c"hi\00", align 1
@fmt.1 = private unnamed_addr constant [6 x i8] c"%lld \00", align 1
@nl.2 = private unnamed_addr constant [2 x i8] c"\0A\00", align 1
@fmt.3 = private unnamed_addr constant [6 x i8] c"%lld \00", align 1
@nl.4 = private unnamed_addr constant [2 x i8] c"\0A\00", align 1
@fmt.5 = private unnamed_addr constant [4 x i8] c"%g \00", align 1
@nl.6 = private unnamed_addr constant [2 x i8] c"\0A\00", align 1

define void @main() {
entry:
  ret void
}

define void @__llts_main() {
entry:
  store i64 42, ptr @sz, align 4
  store i64 10, ptr @usz, align 4
  store i64 7, ptr @maybe, align 4
  %maybe = load i64, ptr @maybe, align 4
  %tobool = trunc i64 %maybe to i1
  br i1 %tobool, label %then, label %else

then:                                             ; preds = %entry
  %val = alloca i64, align 8
  store i64 %maybe, ptr %val, align 4
  %val1 = load i64, ptr %val, align 4
  %0 = call i32 (ptr, ...) @printf(ptr @fmt, i64 %val1)
  %1 = call i32 (ptr, ...) @printf(ptr @nl)
  br label %merge

else:                                             ; preds = %entry
  br label %merge

merge:                                            ; preds = %else, %then
  store ptr @.str, ptr @msg, align 8
  %msg = load [2 x i8], ptr @msg, align 1
  %iter.i = alloca i64, align 8
  store i64 0, ptr %iter.i, align 4
  %ch = alloca i8, align 1
  %iter.arr = alloca [2 x i8], align 1
  store [2 x i8] %msg, ptr %iter.arr, align 1
  br label %iter.cond

iter.cond:                                        ; preds = %iter.body, %merge
  %i = load i64, ptr %iter.i, align 4
  %cmp = icmp ult i64 %i, 2
  br i1 %cmp, label %iter.body, label %iter.end

iter.body:                                        ; preds = %iter.cond
  %ep = getelementptr [2 x i8], ptr %iter.arr, i64 0, i64 %i
  %ev = load i8, ptr %ep, align 1
  store i8 %ev, ptr %ch, align 1
  %ch2 = load i8, ptr %ch, align 1
  %sext = sext i8 %ch2 to i64
  %2 = call i32 (ptr, ...) @printf(ptr @fmt.1, i64 %sext)
  %3 = call i32 (ptr, ...) @printf(ptr @nl.2)
  %next = add i64 %i, 1
  store i64 %next, ptr %iter.i, align 4
  br label %iter.cond

iter.end:                                         ; preds = %iter.cond
  store [3 x i64] [i64 1, i64 2, i64 3], ptr @arr, align 4
  %arr = load [3 x i64], ptr @arr, align 4
  %iter.i3 = alloca i64, align 8
  store i64 0, ptr %iter.i3, align 4
  %elem = alloca i64, align 8
  %i4 = alloca i64, align 8
  store i64 0, ptr %i4, align 4
  %iter.arr5 = alloca [3 x i64], align 8
  store [3 x i64] %arr, ptr %iter.arr5, align 4
  br label %iter.cond6

iter.cond6:                                       ; preds = %iter.body7, %iter.end
  %i9 = load i64, ptr %iter.i3, align 4
  %cmp10 = icmp ult i64 %i9, 3
  br i1 %cmp10, label %iter.body7, label %iter.end8

iter.body7:                                       ; preds = %iter.cond6
  %ep11 = getelementptr [3 x i64], ptr %iter.arr5, i64 0, i64 %i9
  %ev12 = load i64, ptr %ep11, align 4
  store i64 %ev12, ptr %elem, align 4
  store i64 %i9, ptr %i4, align 4
  %elem13 = load i64, ptr %elem, align 4
  %4 = call i32 (ptr, ...) @printf(ptr @fmt.3, i64 %elem13)
  %5 = call i32 (ptr, ...) @printf(ptr @nl.4)
  %next14 = add i64 %i9, 1
  store i64 %next14, ptr %iter.i3, align 4
  store i64 %next14, ptr %i4, align 4
  br label %iter.cond6

iter.end8:                                        ; preds = %iter.cond6
  store double 2.000000e+00, ptr @base, align 8
  store double 8.000000e+00, ptr @exp, align 8
  %base = load double, ptr @base, align 8
  %exp = load double, ptr @exp, align 8
  %pow = call double @llvm.pow.f64(double %base, double %exp)
  store double %pow, ptr @result, align 8
  %result = load double, ptr @result, align 8
  %6 = call i32 (ptr, ...) @printf(ptr @fmt.5, double %result)
  %7 = call i32 (ptr, ...) @printf(ptr @nl.6)
  ret void
}

declare i32 @printf(ptr, ...)

; Function Attrs: nocallback nofree nosync nounwind speculatable willreturn memory(none)
declare double @llvm.pow.f64(double, double) #0

define i32 @main.7() {
entry:
  call void @__llts_main()
  call void @main()
  ret i32 0
}

attributes #0 = { nocallback nofree nosync nounwind speculatable willreturn memory(none) }
